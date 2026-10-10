// Package store 是 SQLite 主库（唯一真相源，架构 §3.3 / §6.1）。
//
// 免费档纪律：热写全落本地 SQLite，D1 只在游戏日边界同步（M1 还没接 D1）。
// 落库节奏：每 10 拍一次批量 flush —— 减少 fsync，也避免每拍一次事务。
package store

import (
	"database/sql"
	"fmt"
	"sync"
	"time"

	_ "modernc.org/sqlite" // 纯 Go 驱动：03-engine-install.sh 用 CGO_ENABLED=0 编译

	"aitown/internal/world"
)

// Store SQLite 主库
type Store struct {
	db *sql.DB
	mu sync.Mutex // 单写者：SQLite 不支持并发写
}

// Open 打开（不存在则创建）数据库，开启 WAL
func Open(path string) (*Store, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// 单连接：SQLite 单写者模型，同时把内存占用压到最低
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	if err := db.Ping(); err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

// Migrate 建表（IF NOT EXISTS，幂等）
func (s *Store) Migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS world (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			tick INTEGER NOT NULL,
			game_day INTEGER NOT NULL,
			game_minute INTEGER NOT NULL,
			speed REAL NOT NULL,
			seed INTEGER NOT NULL,
			status TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS agents (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			persona TEXT,
			home_x INTEGER,
			home_y INTEGER,
			state TEXT,
			mood INTEGER DEFAULT 0,
			tick_updated INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS positions (
			agent_id TEXT PRIMARY KEY,
			x INTEGER NOT NULL,
			y INTEGER NOT NULL,
			facing TEXT,
			path_json TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS events (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			tick INTEGER NOT NULL,
			agent_id TEXT,
			type TEXT NOT NULL,
			payload_json TEXT,
			importance INTEGER DEFAULT 0,
			game_day INTEGER,
			created_at INTEGER
		)`,
		`CREATE INDEX IF NOT EXISTS idx_events_tick ON events(tick)`,
		`CREATE INDEX IF NOT EXISTS idx_events_day ON events(game_day, agent_id)`,
	}
	for _, q := range stmts {
		if _, err := s.db.Exec(q); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	return nil
}

// Flush 把居民状态与位置批量写入（单事务）。events 逐条插入。
func (s *Store) Flush(tick int64, gameDay, gameMinute int, speed float64, seed int64, agents []world.Agent, events []world.Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	now := time.Now().Unix()
	if _, err = tx.Exec(
		`INSERT INTO world (id, tick, game_day, game_minute, speed, seed, status)
		 VALUES (1, ?, ?, ?, ?, ?, 'running')
		 ON CONFLICT(id) DO UPDATE SET tick=excluded.tick, game_day=excluded.game_day,
		   game_minute=excluded.game_minute, speed=excluded.speed, seed=excluded.seed, status=excluded.status`,
		tick, gameDay, gameMinute, speed, seed,
	); err != nil {
		return err
	}

	agentStmt, err := tx.Prepare(
		`INSERT INTO agents (id, name, persona, home_x, home_y, state, mood, tick_updated)
		 VALUES (?, ?, ?, ?, ?, ?, 0, ?)
		 ON CONFLICT(id) DO UPDATE SET name=excluded.name, persona=excluded.persona,
		   home_x=excluded.home_x, home_y=excluded.home_y, state=excluded.state, tick_updated=excluded.tick_updated`)
	if err != nil {
		return err
	}
	defer agentStmt.Close()

	posStmt, err := tx.Prepare(
		`INSERT INTO positions (agent_id, x, y, facing, path_json) VALUES (?, ?, ?, ?, NULL)
		 ON CONFLICT(agent_id) DO UPDATE SET x=excluded.x, y=excluded.y, facing=excluded.facing`)
	if err != nil {
		return err
	}
	defer posStmt.Close()

	for _, a := range agents {
		if _, err = agentStmt.Exec(a.ID, a.Name, a.Persona, a.HomeX, a.HomeY, a.State, tick); err != nil {
			return err
		}
		if _, err = posStmt.Exec(a.ID, a.X, a.Y, a.Facing); err != nil {
			return err
		}
	}

	evStmt, err := tx.Prepare(
		`INSERT INTO events (tick, agent_id, type, payload_json, importance, game_day, created_at)
		 VALUES (?, ?, ?, ?, 0, ?, ?)`)
	if err != nil {
		return err
	}
	defer evStmt.Close()
	for _, e := range events {
		payload := fmt.Sprintf(`{"poi":%q,"name":%q}`, e.POI, e.Name)
		if _, err = evStmt.Exec(e.Tick, e.Agent, e.Kind, payload, gameDay, now); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// CountEvents 事件总数（健康检查用，证明落库真的在写）
func (s *Store) CountEvents() (int64, error) {
	var n int64
	err := s.db.QueryRow(`SELECT COUNT(*) FROM events`).Scan(&n)
	return n, err
}

// LastTick 库里记录的最后拍
func (s *Store) LastTick() (int64, error) {
	var t sql.NullInt64
	err := s.db.QueryRow(`SELECT tick FROM world WHERE id = 1`).Scan(&t)
	if err != nil {
		return 0, err
	}
	return t.Int64, nil
}

// Close 关闭数据库（退出前必须调用，确保 WAL 落盘）
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
	return s.db.Close()
}
