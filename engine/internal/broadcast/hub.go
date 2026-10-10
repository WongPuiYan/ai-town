// Package broadcast 负责 WebSocket 差分帧广播（架构 §4.2 / §2 ⑥）。
//
// 三条纪律：
//   - 只发差分：世界没变就不发（空拍零字节）
//   - 慢客户端直接踢：不为此积压内存（2GB 机器没有余量）
//   - 扇出有上限：AITOWN_MAX_VIEWERS（默认 50）
package broadcast

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	writeTimeout   = 5 * time.Second
	pingInterval   = 30 * time.Second
	clientBuf      = 32
	readLimitBytes = 8 << 10
)

// Hub 管理所有 WebSocket 连接
type Hub struct {
	mu         sync.Mutex
	clients    map[*client]struct{}
	maxViewers int
	dropped    int64
	rejected   int64
}

// client 一个观众连接。所有出站消息都从 send 通道走（WebSocket 不允许并发写）。
type client struct {
	hub    *Hub
	conn   *websocket.Conn
	send   chan []byte
	remote string
	closed bool
}

// NewHub 创建广播中心
func NewHub(maxViewers int) *Hub {
	if maxViewers <= 0 {
		maxViewers = 50
	}
	return &Hub{clients: make(map[*client]struct{}), maxViewers: maxViewers}
}

// Count 当前在线观众数
func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// Stats 可观测性：被踢（慢消费者）与拒绝（超上限）计数
func (h *Hub) Stats() (dropped, rejected int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.dropped, h.rejected
}

// Broadcast 向所有客户端投递一帧；缓冲满的客户端立即断开，绝不阻塞 tick。
func (h *Hub) Broadcast(payload []byte) {
	h.mu.Lock()
	targets := make([]*client, 0, len(h.clients))
	for c := range h.clients {
		targets = append(targets, c)
	}
	h.mu.Unlock()

	for _, c := range targets {
		select {
		case c.send <- payload:
		default:
			h.mu.Lock()
			h.dropped++
			h.mu.Unlock()
			log.Printf("[ws] 客户端 %s 消费过慢，断开（缓冲 %d 满）", c.remote, clientBuf)
			c.close(websocket.StatusPolicyViolation, "slow consumer")
		}
	}
}

// Serve 升级 HTTP 请求为 WebSocket，并启动该客户端的读写循环。
// snapshot 用于初次接入与客户端主动 resync；onMessage 处理业务消息（M1 传 nil）。
func (h *Hub) Serve(w http.ResponseWriter, r *http.Request, snapshot func() []byte, onMessage func(*Conn, []byte)) {
	if h.Count() >= h.maxViewers {
		h.mu.Lock()
		h.rejected++
		h.mu.Unlock()
		http.Error(w, "too many viewers", http.StatusServiceUnavailable)
		return
	}

	// 连接只来自本机 tunnel/edge（127.0.0.1 绑定 + edge 侧 token 校验），
	// 因此这里不做 Origin 白名单（Worker fetch 转发的 Origin 不可靠）。
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		log.Printf("[ws] 升级失败: %v", err)
		return
	}
	conn.SetReadLimit(readLimitBytes)

	c := &client{hub: h, conn: conn, send: make(chan []byte, clientBuf), remote: r.RemoteAddr}
	h.mu.Lock()
	h.clients[c] = struct{}{}
	h.mu.Unlock()

	ctx := context.Background()
	c.push(snapshot())
	go c.writeLoop(ctx)
	go c.readLoop(ctx, snapshot, onMessage)
}

// Conn 暴露给业务回调的最小接口（M2 起用于「插话」等入站消息）
type Conn struct {
	c *client
}

// Send 发送一条文本帧
func (c *Conn) Send(payload []byte) { c.c.push(payload) }

// IP 对端地址
func (c *Conn) IP() string { return c.c.remote }

// jsonMsg 组装一条控制消息
func jsonMsg(kind string, extra map[string]any) []byte {
	m := map[string]any{"t": kind}
	for k, v := range extra {
		m[k] = v
	}
	b, _ := json.Marshal(m)
	return b
}

// push 入队一条消息；队列满即断开（保护引擎内存）
func (c *client) push(payload []byte) {
	select {
	case c.send <- payload:
	default:
		c.close(websocket.StatusPolicyViolation, "slow consumer")
	}
}

func (c *client) close(code websocket.StatusCode, reason string) {
	c.hub.mu.Lock()
	if c.closed {
		c.hub.mu.Unlock()
		return
	}
	c.closed = true
	delete(c.hub.clients, c)
	c.hub.mu.Unlock()
	_ = c.conn.Close(code, reason)
	close(c.send)
}

// readLoop 读客户端消息：ping / snapshot（M1 只有这两种）
func (c *client) readLoop(ctx context.Context, snapshot func() []byte, onMessage func(*Conn, []byte)) {
	defer c.close(websocket.StatusNormalClosure, "read loop exit")
	for {
		typ, data, err := c.conn.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var msg struct {
			T string `json:"t"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			c.push(jsonMsg("error", map[string]any{"msg": "invalid json"}))
			continue
		}
		switch msg.T {
		case "ping":
			c.push(jsonMsg("pong", map[string]any{"ts": time.Now().UnixMilli()}))
		case "snapshot":
			c.push(snapshot())
		default:
			if onMessage != nil {
				onMessage(&Conn{c: c}, data)
			} else {
				c.push(jsonMsg("error", map[string]any{"msg": "unsupported: " + msg.T}))
			}
		}
	}
}

// writeLoop 单写者循环 + 每 30s 一次协议级 ping（保活，穿 tunnel）
func (c *client) writeLoop(ctx context.Context) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()
	for {
		select {
		case msg, ok := <-c.send:
			if !ok {
				return
			}
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.conn.Write(wctx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				c.close(websocket.StatusAbnormalClosure, "write failed")
				return
			}
		case <-ticker.C:
			pctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.conn.Ping(pctx)
			cancel()
			if err != nil {
				c.close(websocket.StatusAbnormalClosure, "ping failed")
				return
			}
		}
	}
}
