// Package world 持有小镇的全部内存状态：地图、地点、居民、游戏时钟。
//
// 设计要点（对齐 docs/ARCHITECTURE.md §4.2）：
//   1 tick = 一次世界推进；游戏时钟由 tick 推导，便于加速/暂停/回放（M5）。
//   M1 阶段居民决策是**纯规则**（零 LLM）：到点选目的地 → BFS 寻路 → 走到 → 停留。
package world

import (
	"fmt"
	"math"
	"math/rand"
	"sync"
)

// 居民状态（M1 只有两个，M2 加 talk/reflect）
const (
	StateIdle = "idle"
	StateMove = "move"
)

const (
	GameMinutesPerDay = 1440 // 游戏日内固定 1440 分钟
)

// Point 网格坐标（左上为原点）
type Point struct{ X, Y int }

// POI 兴趣点：居民的目的地。W/H 是占地范围，不计入可行走区域。
type POI struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	X    int    `json:"x"`
	Y    int    `json:"y"`
	W    int    `json:"w"`
	H    int    `json:"h"`
	Kind string `json:"kind"` // home / work / leisure
}

// Center 返回 POI 的中心点
func (p POI) Center() Point { return Point{X: p.X + p.W/2, Y: p.Y + p.H/2} }

// Contains 该点是否落在 POI 占地内
func (p POI) Contains(x, y int) bool {
	return x >= p.X && x < p.X+p.W && y >= p.Y && y < p.Y+p.H
}

// Agent 一位居民。字段直接用于 JSON 广播（省略 path 等内部字段）。
type Agent struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Persona string `json:"persona"`
	Color   string `json:"color"`
	HomeX   int    `json:"homeX"`
	HomeY   int    `json:"homeY"`
	X       int    `json:"x"`
	Y       int    `json:"y"`
	Facing  string `json:"facing"`
	State   string `json:"state"`
	Target  string `json:"target,omitempty"` // 目标 POI id

	path []Point // 待走路径（内部）
	wait int     // 停留剩余拍数（内部）
}

// Event 一条世界事件（M1 只有 arrive；M2 加 talk 等）
type Event struct {
	Kind  string `json:"kind"`
	Agent string `json:"agent"`
	Name  string `json:"name,omitempty"`
	POI   string `json:"poi,omitempty"`
	Tick  int64  `json:"tick"`
}

// Diff 每拍增量（只有发生变化才发，空拍不占带宽 —— 架构 §4.2）
type Diff struct {
	T           string  `json:"t"`
	Tick        int64   `json:"tick"`
	GameDay     int     `json:"gameDay"`
	MinuteOfDay int     `json:"minuteOfDay"`
	Clock       string  `json:"clock"`
	Speed       float64 `json:"speed"`
	Upd         []Agent `json:"upd,omitempty"`
	Events      []Event `json:"events,omitempty"`
}

// Snapshot 全量快照（新观众接入 / 断线重连时发一次）
type Snapshot struct {
	T           string  `json:"t"`
	V           int     `json:"v"`
	Tick        int64   `json:"tick"`
	GameDay     int     `json:"gameDay"`
	MinuteOfDay int     `json:"minuteOfDay"`
	Clock       string  `json:"clock"`
	Speed       float64 `json:"speed"`
	GridW       int     `json:"gridW"`
	GridH       int     `json:"gridH"`
	POIs        []POI   `json:"pois"`
	Agents      []Agent `json:"agents"`
}

// Config 世界参数
type Config struct {
	W              int
	H              int
	Seed           int64
	GameDaySeconds int // 1 个游戏日 = 多少现实秒
	TickSeconds    int // 每拍多少现实秒
}

// World 小镇世界状态。所有公开方法都带锁。
type World struct {
	mu     sync.RWMutex
	cfg    Config
	grid   []bool // true = 障碍（POI 占地）
	pois   []POI
	agents []*Agent
	tick   int64
	speed  float64
	rng    *rand.Rand
}

// New 构建世界（地图 + 地点 + 居民）
func New(cfg Config) *World {
	if cfg.W <= 0 {
		cfg.W = 64
	}
	if cfg.H <= 0 {
		cfg.H = 64
	}
	if cfg.Seed == 0 {
		cfg.Seed = 20260922
	}
	if cfg.GameDaySeconds <= 0 {
		cfg.GameDaySeconds = 7200
	}
	if cfg.TickSeconds <= 0 {
		cfg.TickSeconds = 1
	}
	w := &World{
		cfg:   cfg,
		grid:  make([]bool, cfg.W*cfg.H),
		speed: 1,
		rng:   rand.New(rand.NewSource(cfg.Seed)),
	}
	w.buildPOIs()
	w.spawnAgents()
	return w
}

// ────────────────────────────── 地图 ──────────────────────────────

func (w *World) buildPOIs() {
	w.pois = []POI{
		{ID: "home", Name: "住处", X: 4, Y: 4, W: 8, H: 6, Kind: "home"},
		{ID: "cafe", Name: "咖啡店", X: 26, Y: 8, W: 7, H: 5, Kind: "leisure"},
		{ID: "library", Name: "图书馆", X: 48, Y: 6, W: 9, H: 7, Kind: "leisure"},
		{ID: "market", Name: "市集", X: 12, Y: 30, W: 10, H: 6, Kind: "work"},
		{ID: "plaza", Name: "广场", X: 34, Y: 34, W: 12, H: 10, Kind: "leisure"},
		{ID: "park", Name: "公园", X: 8, Y: 48, W: 14, H: 9, Kind: "leisure"},
		{ID: "office", Name: "工作室", X: 48, Y: 40, W: 10, H: 8, Kind: "work"},
	}
	for _, p := range w.pois {
		for y := p.Y; y < p.Y+p.H; y++ {
			for x := p.X; x < p.X+p.W; x++ {
				if w.inBounds(x, y) {
					w.grid[y*w.cfg.W+x] = true
				}
			}
		}
	}
}

func (w *World) inBounds(x, y int) bool {
	return x >= 0 && y >= 0 && x < w.cfg.W && y < w.cfg.H
}

func (w *World) blocked(x, y int) bool {
	if !w.inBounds(x, y) {
		return true
	}
	return w.grid[y*w.cfg.W+x]
}

// walkable 返回某个 POI 外圈的一个可走点（居民实际站的位置）
func (w *World) walkableNear(p POI) Point {
	c := p.Center()
	// 从中心向外螺旋找第一个可走点
	for r := 1; r < 12; r++ {
		for _, d := range [][2]int{{0, r}, {r, 0}, {0, -r}, {-r, 0}, {r, r}, {-r, r}, {r, -r}, {-r, -r}} {
			x, y := c.X+d[0], c.Y+d[1]
			if !w.blocked(x, y) {
				return Point{x, y}
			}
		}
	}
	return Point{0, 0}
}

func (w *World) poiByID(id string) (POI, bool) {
	for _, p := range w.pois {
		if p.ID == id {
			return p, true
		}
	}
	return POI{}, false
}

// bfs 4 邻域广度优先寻路，返回不含起点的路径
func (w *World) bfs(from, to Point) []Point {
	if from == to {
		return nil
	}
	W := w.cfg.W
	prev := make([]int32, W*w.cfg.H)
	for i := range prev {
		prev[i] = -1
	}
	start := from.Y*W + from.X
	goal := to.Y*W + to.X
	prev[start] = int32(start)
	queue := []Point{from}
	found := false
	for len(queue) > 0 && !found {
		cur := queue[0]
		queue = queue[1:]
		for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
			nx, ny := cur.X+d[0], cur.Y+d[1]
			if w.blocked(nx, ny) {
				continue
			}
			idx := ny*W + nx
			if prev[idx] != -1 {
				continue
			}
			prev[idx] = int32(cur.Y*W + cur.X)
			if idx == goal {
				found = true
				break
			}
			queue = append(queue, Point{nx, ny})
		}
	}
	if !found {
		return nil
	}
	var rev []Point
	for idx := goal; idx != start; idx = int(prev[idx]) {
		rev = append(rev, Point{idx % W, idx / W})
	}
	// 反转
	path := make([]Point, 0, len(rev))
	for i := len(rev) - 1; i >= 0; i-- {
		path = append(path, rev[i])
	}
	return path
}

// ────────────────────────────── 居民 ──────────────────────────────

type persona struct {
	name, desc, color string
	homePOI           string
}

var personas = []persona{
	{"阿明", "深圳来的后端工程师，习惯早起，喜欢在咖啡馆写代码", "#4f9cf9", "home"},
	{"小美", "花店老板娘，话多热情，爱逛市集", "#f97fb5", "home"},
	{"老陈", "退休教师，每天泡图书馆看报", "#8f7bf9", "home"},
	{"阿强", "外卖骑手，全城跑，认识每个人", "#f9a34f", "home"},
	{"晓雯", "自由插画师，常去公园写生", "#4fd8c4", "home"},
	{"阿杰", "健身房教练，作息规律，晚上才出门", "#f96b6b", "home"},
	{"小雨", "大学生，爱笑，喜欢待在广场听人弹吉他", "#b8f94f", "home"},
	{"老王", "杂货铺老板，下午总在工作室盘货", "#f9e04f", "home"},
}

func (w *World) spawnAgents() {
	home, _ := w.poiByID("home")
	used := make(map[int]bool)
	for i, p := range personas {
		spot := w.walkableNear(home)
		// 找出身边一个没被占的格子，避免两个居民重叠出生
		for tries := 0; tries < 400; tries++ {
			x := spot.X + w.rng.Intn(17) - 8
			y := spot.Y + w.rng.Intn(17) - 8
			if w.blocked(x, y) || used[y*w.cfg.W+x] {
				continue
			}
			spot = Point{x, y}
			used[y*w.cfg.W+x] = true
			break
		}
		a := &Agent{
			ID:      fmt.Sprintf("a%02d", i+1),
			Name:    p.name,
			Persona: p.desc,
			Color:   p.color,
			X:       spot.X,
			Y:       spot.Y,
			Facing:  "down",
			State:   StateIdle,
			HomeX:   home.Center().X,
			HomeY:   home.Center().Y,
			wait:    w.rng.Intn(30),
		}
		w.agents = append(w.agents, a)
	}
}

// ────────────────────────────── 时间 ──────────────────────────────

// ticksPerGameDay 一个游戏日有多少拍
func (w *World) ticksPerGameDay() float64 {
	return float64(w.cfg.GameDaySeconds) / float64(w.cfg.TickSeconds)
}

// clockOf 由 tick 推导游戏时间：游戏日序号 + 当日分钟 + HH:MM
func (w *World) clockOf(tick int64) (int, int, string) {
	minPerTick := float64(GameMinutesPerDay) / w.ticksPerGameDay()
	total := float64(tick) * minPerTick
	day := int(total / GameMinutesPerDay)
	minute := int(math.Mod(total, GameMinutesPerDay))
	return day, minute, fmt.Sprintf("%02d:%02d", minute/60, minute%60)
}

// Clock 当前游戏时间
func (w *World) Clock() (day, minute int, hhmm string) {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.clockOf(w.tick)
}

// Tick 当前拍数
func (w *World) Tick() int64 {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.tick
}

// Speed 当前倍速
func (w *World) Speed() float64 {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.speed
}

// SetSpeed 设置倍速（M5 会暴露成 API）
func (w *World) SetSpeed(s float64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if s > 0 && s <= 16 {
		w.speed = s
	}
}

// ────────────────────────────── 推进 ──────────────────────────────

// Step 推进一拍，返回增量帧内容。返回的 Upd 只含发生变化的居民。
func (w *World) Step() ([]Agent, []Event) {
	w.mu.Lock()
	defer w.mu.Unlock()

	w.tick++
	var upd []Agent
	var events []Event

	for _, a := range w.agents {
		before := *a
		w.stepAgent(a, &events)
		if before.X != a.X || before.Y != a.Y || before.State != a.State || before.Facing != a.Facing || before.Target != a.Target {
			upd = append(upd, *a)
		}
	}
	return upd, events
}

func (w *World) stepAgent(a *Agent, events *[]Event) {
	if len(a.path) > 0 {
		next := a.path[0]
		a.path = a.path[1:]
		if next.X > a.X {
			a.Facing = "right"
		} else if next.X < a.X {
			a.Facing = "left"
		} else if next.Y > a.Y {
			a.Facing = "down"
		} else if next.Y < a.Y {
			a.Facing = "up"
		}
		a.X, a.Y = next.X, next.Y
		a.State = StateMove
		if len(a.path) == 0 {
			// 抵达目的地 → 停留一会儿（M2 这里会变成「开始做事/社交」）
			a.State = StateIdle
			a.wait = 8 + w.rng.Intn(22)
			*events = append(*events, Event{Kind: "arrive", Agent: a.ID, Name: a.Name, POI: a.Target, Tick: w.tick})
		}
		return
	}

	if a.wait > 0 {
		a.wait--
		a.State = StateIdle
		return
	}

	// 选下一个目的地：离家远近随机，让小镇看起来有作息
	target := w.pickTarget(a)
	dest := POI{}
	if p, ok := w.poiByID(target); ok {
		dest = p
	}
	spot := w.walkableNear(dest)
	if path := w.bfs(Point{a.X, a.Y}, spot); len(path) > 0 {
		a.path = path
		a.Target = target
		a.State = StateMove
		*events = append(*events, Event{Kind: "depart", Agent: a.ID, Name: a.Name, POI: target, Tick: w.tick})
	} else {
		a.wait = 5 + w.rng.Intn(10)
	}
}

// pickTarget 选目的地：80% 随机挑一个 POI，20% 回家
func (w *World) pickTarget(a *Agent) string {
	if w.rng.Float64() < 0.2 {
		return "home"
	}
	for i := 0; i < 8; i++ {
		p := w.pois[w.rng.Intn(len(w.pois))]
		if p.ID != a.Target && p.ID != "home" {
			return p.ID
		}
	}
	return "home"
}

// Snapshot 生成全量快照
func (w *World) Snapshot() Snapshot {
	w.mu.RLock()
	defer w.mu.RUnlock()
	day, minute, hhmm := w.clockOf(w.tick)
	agents := make([]Agent, 0, len(w.agents))
	for _, a := range w.agents {
		agents = append(agents, *a)
	}
	return Snapshot{
		T: "snapshot", V: 1,
		Tick: w.tick, GameDay: day, MinuteOfDay: minute, Clock: hhmm,
		Speed: w.speed, GridW: w.cfg.W, GridH: w.cfg.H,
		POIs: w.pois, Agents: agents,
	}
}

// DiffFrame 把 Step 的结果打包成广播帧
func (w *World) DiffFrame(upd []Agent, events []Event) Diff {
	w.mu.RLock()
	defer w.mu.RUnlock()
	day, minute, hhmm := w.clockOf(w.tick)
	return Diff{
		T: "diff", Tick: w.tick, GameDay: day, MinuteOfDay: minute, Clock: hhmm,
		Speed: w.speed, Upd: upd, Events: events,
	}
}

// AgentCount 居民数
func (w *World) AgentCount() int {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return len(w.agents)
}

// AllAgents 用于落库的居民快照
func (w *World) AllAgents() []Agent {
	w.mu.RLock()
	defer w.mu.RUnlock()
	out := make([]Agent, 0, len(w.agents))
	for _, a := range w.agents {
		out = append(out, *a)
	}
	return out
}

// POIs 地点列表
func (w *World) POIs() []POI {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return append([]POI(nil), w.pois...)
}
