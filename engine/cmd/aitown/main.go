// Command aitown 是小镇引擎（架构 §4）：跑世界时钟、驱动居民、广播差分帧、落 SQLite。
//
// M1 范围：心跳（tick 循环）+ 血管（WebSocket 差分广播 + 落库）。
// 明确不做：不调任何 LLM、不接 DeepSeek、不碰 Workers AI —— 零成本可跑。
//
// 部署形态：127.0.0.1:8080，由 cloudflared quick tunnel 暴露，edge Worker 做哑管道。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"aitown/internal/broadcast"
	"aitown/internal/store"
	"aitown/internal/world"
)

const version = "0.1.0-m1"

// flushEvery 每多少拍落一次库（架构 §6.2：热写批量 flush，避免每拍一个事务）
const flushEvery = 10

type config struct {
	addr        string
	dbPath      string
	seed        int64
	grid        int
	tickSeconds int
	gameDaySecs int
	maxViewers  int
	speed       float64
	edgeToken   string
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("[cfg] %s=%q 不是整数，用默认值 %d", key, v, def)
	}
	return def
}

func loadConfig() config {
	home, _ := os.UserHomeDir()
	return config{
		addr:        envOr("AITOWN_ADDR", "127.0.0.1:8080"),
		dbPath:      envOr("AITOWN_DB", filepath.Join(home, "ai-town", "data", "aitown.db")),
		seed:        int64(envInt("AITOWN_SEED", 20260922)),
		grid:        envInt("AITOWN_GRID", 64),
		tickSeconds: envInt("AITOWN_TICK_SECONDS", 1),
		gameDaySecs: envInt("AITOWN_GAME_DAY_SECONDS", 7200),
		maxViewers:  envInt("AITOWN_MAX_VIEWERS", 50),
		speed:       float64(envInt("AITOWN_SPEED", 1)),
		edgeToken:   os.Getenv("AITOWN_EDGE_TOKEN"),
	}
}

func main() {
	cfg := loadConfig()
	// 命令行优先（本地调试用）
	flag.StringVar(&cfg.addr, "addr", cfg.addr, "监听地址")
	flag.StringVar(&cfg.dbPath, "db", cfg.dbPath, "SQLite 路径")
	flag.Int64Var(&cfg.seed, "seed", cfg.seed, "随机种子（同种子=同世界）")
	flag.IntVar(&cfg.grid, "grid", cfg.grid, "地图边长")
	flag.IntVar(&cfg.tickSeconds, "tick", cfg.tickSeconds, "每拍现实秒数")
	flag.IntVar(&cfg.gameDaySecs, "gameday", cfg.gameDaySecs, "一个游戏日多少现实秒")
	flag.IntVar(&cfg.maxViewers, "viewers", cfg.maxViewers, "最大在线观众")
	flag.Float64Var(&cfg.speed, "speed", cfg.speed, "倍速")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[aitown] ")
	log.Printf("引擎启动 version=%s addr=%s db=%s seed=%d grid=%d 游戏日=%ds",
		version, cfg.addr, cfg.dbPath, cfg.seed, cfg.grid, cfg.gameDaySecs)

	if err := os.MkdirAll(filepath.Dir(cfg.dbPath), 0o755); err != nil {
		log.Fatalf("创建数据目录失败: %v", err)
	}

	st, err := store.Open(cfg.dbPath)
	if err != nil {
		log.Fatalf("打开 SQLite 失败: %v", err)
	}
	if err := st.Migrate(); err != nil {
		log.Fatalf("建表失败: %v", err)
	}

	w := world.New(world.Config{
		W: cfg.grid, H: cfg.grid, Seed: cfg.seed,
		GameDaySeconds: cfg.gameDaySecs, TickSeconds: cfg.tickSeconds,
	})
	w.SetSpeed(cfg.speed)

	hub := broadcast.NewHub(cfg.maxViewers)

	// 起始状态先落一次库，保证「重启后世界不凭空消失」
	day, minute, _ := w.Clock()
	if err := st.Flush(w.Tick(), day, minute, w.Speed(), cfg.seed, w.AllAgents(), nil); err != nil {
		log.Printf("初始落库失败: %v", err)
	}

	var startedAt = time.Now()
	var ticksRun, framesSent atomic.Int64

	// ── 心跳：世界时钟 ──
	stop := make(chan struct{})
	go func() {
		var pending []world.Event
		for {
			speed := w.Speed()
			interval := time.Duration(float64(cfg.tickSeconds) / speed * float64(time.Second))
			if interval < time.Millisecond {
				interval = time.Millisecond
			}
			select {
			case <-stop:
				return
			case <-time.After(interval):
			}

			upd, events := w.Step()
			ticksRun.Add(1)
			pending = append(pending, events...)

			// 血管：有变化才发帧（空拍零字节）
			if len(upd) > 0 || len(events) > 0 {
				if payload, err := json.Marshal(w.DiffFrame(upd, events)); err == nil {
					hub.Broadcast(payload)
					framesSent.Add(1)
				}
			}

			if w.Tick()%flushEvery == 0 {
				d, m, _ := w.Clock()
				if err := st.Flush(w.Tick(), d, m, speed, cfg.seed, w.AllAgents(), pending); err != nil {
					log.Printf("落库失败 tick=%d: %v", w.Tick(), err)
				}
				pending = pending[:0]
			}
		}
	}()

	// ── HTTP 面 ──
	mux := http.NewServeMux()

	snapshotJSON := func() []byte {
		b, err := json.Marshal(w.Snapshot())
		if err != nil {
			return []byte(`{"t":"error","msg":"marshal"}`)
		}
		return b
	}

	authed := func(next http.HandlerFunc) http.HandlerFunc {
		return func(rw http.ResponseWriter, r *http.Request) {
			if cfg.edgeToken != "" {
				tok := r.Header.Get("X-Edge-Token")
				if tok == "" {
					tok = r.URL.Query().Get("token")
				}
				if tok != cfg.edgeToken {
					http.Error(rw, "unauthorized", http.StatusUnauthorized)
					return
				}
			}
			next(rw, r)
		}
	}

	mux.HandleFunc("/health", func(rw http.ResponseWriter, r *http.Request) {
		day, minute, hhmm := w.Clock()
		events, _ := st.CountEvents()
		dropped, rejected := hub.Stats()
		writeJSON(rw, map[string]any{
			"ok": true, "version": version, "engine": "aitown",
			"tick": w.Tick(), "gameDay": day, "minuteOfDay": minute, "clock": hhmm,
			"speed": w.Speed(), "agents": w.AgentCount(),
			"viewers": hub.Count(), "maxViewers": cfg.maxViewers,
			"droppedClients": dropped, "rejectedClients": rejected,
			"dbEvents": events, "ticksRun": ticksRun.Load(), "framesSent": framesSent.Load(),
			"uptimeSeconds": int(time.Since(startedAt).Seconds()),
		})
	})

	mux.HandleFunc("/api/state", authed(func(rw http.ResponseWriter, r *http.Request) {
		rw.Header().Set("Content-Type", "application/json")
		_, _ = rw.Write(snapshotJSON())
	}))

	mux.HandleFunc("/ws", authed(func(rw http.ResponseWriter, r *http.Request) {
		hub.Serve(rw, r, snapshotJSON, nil)
	}))

	srv := &http.Server{
		Addr:              cfg.addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		log.Printf("监听 http://%s  (/health /api/state /ws)", cfg.addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP 服务退出: %v", err)
		}
	}()

	// ── 优雅退出：落盘最后一拍 ──
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Printf("收到退出信号，正在收尾（tick=%d）", w.Tick())
	close(stop)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)

	day, minute, _ = w.Clock()
	if err := st.Flush(w.Tick(), day, minute, w.Speed(), cfg.seed, w.AllAgents(), nil); err != nil {
		log.Printf("退出落库失败: %v", err)
	}
	if err := st.Close(); err != nil {
		log.Printf("关闭数据库失败: %v", err)
	}
	log.Printf("已退出。跑了 %d 拍，广播 %d 帧", ticksRun.Load(), framesSent.Load())
}

func writeJSON(rw http.ResponseWriter, v any) {
	rw.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(rw)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}
