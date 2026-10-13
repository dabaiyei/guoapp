package core

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	nativeCastRenderer  = "urn:schemas-upnp-org:device:MediaRenderer:1"
	nativeCastTransport = "urn:schemas-upnp-org:service:AVTransport:1"
	nativeCastRendering = "urn:schemas-upnp-org:service:RenderingControl:1"
	nativeCastLimit     = 400 << 10
	nativeCastSearch    = 2200 * time.Millisecond
	nativeCastProbe     = 8 * time.Second
)

type nativeCastInput struct {
	Device    string `json:"device"`
	Session   string `json:"session"`
	Title     string `json:"title"`
	Host      string `json:"host"`
	Unit      string `json:"unit"`
	TargetMS  int64  `json:"targetMs"`
	Volume    int    `json:"volume"`
	HasVolume bool   `json:"hasVolume"`
	Scan      bool   `json:"scan"`
}

type nativeCastDevice struct {
	ID                  string `json:"id"`
	Name                string `json:"name"`
	Model               string `json:"model"`
	Address             string `json:"address"`
	ControlURL          string `json:"controlUrl"`
	ServiceType         string `json:"serviceType"`
	RenderingControlURL string `json:"renderingControlUrl,omitempty"`
}

type nativeCastSession struct {
	device        nativeCastDevice
	streamSession string
	session       string
	title         string
	started       time.Time
}

type nativeUPnPService struct {
	ServiceType string `xml:"serviceType"`
	ControlURL  string `xml:"controlURL"`
}

type nativeUPnPDevice struct {
	FriendlyName string `xml:"friendlyName"`
	Manufacturer string `xml:"manufacturer"`
	ModelName    string `xml:"modelName"`
	ServiceList  struct {
		Services []nativeUPnPService `xml:"service"`
	} `xml:"serviceList"`
	DeviceList struct {
		Devices []nativeUPnPDevice `xml:"device"`
	} `xml:"deviceList"`
}

type nativeUPnPDescription struct {
	Device nativeUPnPDevice `xml:"device"`
}

func nativeCastMessage() string {
	return strings.Join([]string{
		"M-SEARCH * HTTP/1.1",
		"HOST: 239.255.255.250:1900",
		`MAN: "ssdp:discover"`,
		"MX: 2",
		"ST: " + nativeCastRenderer,
		"USER-AGENT: duanju-cast/1.0",
		"", "",
	}, "\r\n")
}

func nativeSSDPLocation(payload string) string {
	for _, line := range strings.Split(strings.ReplaceAll(payload, "\r\n", "\n"), "\n") {
		name, value, found := strings.Cut(line, ":")
		if found && strings.EqualFold(strings.TrimSpace(name), "LOCATION") {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func nativeCastUDPAddress(host string) *net.UDPAddr {
	host = strings.TrimSpace(host)
	if host == "" {
		return nil
	}
	if _, _, err := net.SplitHostPort(host); err != nil {
		host = net.JoinHostPort(host, "1900")
	}
	address, err := net.ResolveUDPAddr("udp4", host)
	if err != nil {
		return nil
	}
	return address
}

func nativeCastExchange(targets []*net.UDPAddr, deadline time.Duration) []string {
	message := nativeCastMessage()
	list := []string{}
	seen := map[string]bool{}
	record := func(payload string) {
		location := nativeSSDPLocation(payload)
		if location != "" && !seen[location] {
			seen[location] = true
			list = append(list, location)
		}
	}
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		return list
	}
	defer conn.Close()
	stop := time.Now().Add(deadline)
	_ = conn.SetWriteDeadline(stop)
	for _, target := range targets {
		if target == nil {
			continue
		}
		_, _ = conn.WriteToUDP([]byte(message), target)
	}
	_ = conn.SetReadDeadline(stop)
	buffer := make([]byte, 4096)
	for {
		size, _, err := conn.ReadFromUDP(buffer)
		if err != nil {
			break
		}
		if size > 0 {
			record(string(buffer[:size]))
		}
	}
	return list
}

func nativeCastSubnetTargets(host string) []*net.UDPAddr {
	parsed := net.ParseIP(host).To4()
	if parsed == nil {
		return nil
	}
	prefix := fmt.Sprintf("%d.%d.%d.", parsed[0], parsed[1], parsed[2])
	targets := make([]*net.UDPAddr, 0, 254)
	for value := 1; value <= 254; value++ {
		if address := nativeCastUDPAddress(prefix + strconv.Itoa(value)); address != nil {
			targets = append(targets, address)
		}
	}
	return targets
}

func nativeCastMulticastTargets() []*net.UDPAddr {
	return []*net.UDPAddr{{IP: net.IPv4(239, 255, 255, 250), Port: 1900}}
}

func nativeLANIPv4() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	private, linkLocal := "", ""
	for _, network := range interfaces {
		if network.Flags&net.FlagUp == 0 || network.Flags&net.FlagLoopback != 0 {
			continue
		}
		if network.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		rows, _ := network.Addrs()
		for _, row := range rows {
			host, _, err := net.ParseCIDR(row.String())
			if err != nil || host.IsLoopback() || host.To4() == nil {
				continue
			}
			if host.IsPrivate() {
				if private == "" {
					private = host.String()
				}
			} else if host.IsLinkLocalUnicast() && linkLocal == "" {
				linkLocal = host.String()
			}
		}
	}
	if private != "" {
		return private
	}
	return linkLocal
}

func nativeCastCollect(node nativeUPnPDevice, out *[]nativeUPnPDevice) {
	*out = append(*out, node)
	for _, child := range node.DeviceList.Devices {
		nativeCastCollect(child, out)
	}
}

func nativeCastResolveURL(base *url.URL, reference string) string {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return ""
	}
	parsed, err := url.Parse(reference)
	if err != nil {
		return ""
	}
	if base == nil {
		return parsed.String()
	}
	return base.ResolveReference(parsed).String()
}

func nativeCastDescribe(ctx context.Context, location string) (nativeCastDevice, bool) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, location, nil)
	if err != nil {
		return nativeCastDevice{}, false
	}
	request.Header.Set("User-Agent", userAgent)
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return nativeCastDevice{}, false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nativeCastDevice{}, false
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, nativeCastLimit))
	if err != nil {
		return nativeCastDevice{}, false
	}
	return nativeCastParseDescription(body, location)
}

func nativeCastParseDescription(body []byte, location string) (nativeCastDevice, bool) {
	var description nativeUPnPDescription
	if xml.Unmarshal(body, &description) != nil {
		return nativeCastDevice{}, false
	}
	nodes := []nativeUPnPDevice{}
	nativeCastCollect(description.Device, &nodes)
	base, _ := url.Parse(location)
	fallback := ""
	for _, node := range nodes {
		name := strings.TrimSpace(node.FriendlyName)
		if name == "" {
			name = strings.TrimSpace(node.ModelName)
		}
		if fallback == "" && name != "" {
			fallback = name
		}
		device := nativeCastDevice{Address: location, Name: name, Model: strings.TrimSpace(node.ModelName)}
		for _, service := range node.ServiceList.Services {
			control := nativeCastResolveURL(base, service.ControlURL)
			switch {
			case strings.Contains(service.ServiceType, ":service:AVTransport:"):
				if device.ControlURL == "" {
					device.ControlURL, device.ServiceType = control, service.ServiceType
				}
			case strings.Contains(service.ServiceType, ":service:RenderingControl:"):
				if device.RenderingControlURL == "" {
					device.RenderingControlURL = control
				}
			}
		}
		if device.ControlURL == "" {
			continue
		}
		if device.Name == "" {
			device.Name = fallback
		}
		if device.Name == "" {
			device.Name = "投屏设备"
		}
		device.ID = device.ControlURL
		return device, true
	}
	return nativeCastDevice{}, false
}

func (engine *nativeEngine) nativeCastDiscover(ctx context.Context, input nativeCastInput) (any, error) {
	locations := []string{}
	seen := map[string]bool{}
	add := func(values []string) {
		for _, location := range values {
			if location != "" && !seen[location] {
				seen[location] = true
				locations = append(locations, location)
			}
		}
	}
	add(nativeCastExchange(nativeCastMulticastTargets(), nativeCastSearch))
	if host := nativeCastUDPAddress(input.Host); host != nil {
		add(nativeCastExchange([]*net.UDPAddr{host}, nativeCastSearch))
	}
	// 单播扫描整个子网：iOS 发送组播需要 Apple 特批权限，单播不受限，是更可靠的发现路径。
	host := nativeLANIPv4()
	if host != "" {
		add(nativeCastExchange(nativeCastSubnetTargets(host), nativeCastSearch+600*time.Millisecond))
	}
	devices := []nativeCastDevice{}
	mu := sync.Mutex{}
	group := sync.WaitGroup{}
	for _, location := range locations {
		if err := ctx.Err(); err != nil {
			break
		}
		group.Add(1)
		go func(address string) {
			defer group.Done()
			device, ok := nativeCastDescribe(ctx, address)
			if !ok {
				return
			}
			mu.Lock()
			devices = append(devices, device)
			mu.Unlock()
		}(location)
	}
	group.Wait()
	sort.SliceStable(devices, func(i, j int) bool { return devices[i].Name < devices[j].Name })
	engine.castMu.Lock()
	if engine.castDevices == nil {
		engine.castDevices = map[string]nativeCastDevice{}
	}
	for _, device := range devices {
		engine.castDevices[device.ID] = device
	}
	engine.castMu.Unlock()
	return map[string]any{"devices": devices, "localAddress": host}, nil
}

func (engine *nativeEngine) nativeCastDevice(id string) (nativeCastDevice, error) {
	engine.castMu.Lock()
	defer engine.castMu.Unlock()
	if engine.castDevices == nil {
		return nativeCastDevice{}, errors.New("请先搜索投屏设备")
	}
	device, found := engine.castDevices[id]
	if !found || device.ControlURL == "" {
		return nativeCastDevice{}, errors.New("投屏设备已失效，请重新搜索")
	}
	return device, nil
}

func (engine *nativeEngine) nativeCastStreamServer() (*nativeStreamServer, error) {
	engine.castMu.Lock()
	defer engine.castMu.Unlock()
	if engine.castServer != nil {
		return engine.castServer, nil
	}
	host := nativeLANIPv4()
	if host == "" {
		return nil, errors.New("未连接到局域网，请检查 Wi-Fi 后重试")
	}
	server, err := newNativeStreamServerAt(engine.downloader, ":0")
	if err != nil {
		return nil, err
	}
	server.publicAddress = "http://" + net.JoinHostPort(host, strconv.Itoa(server.port))
	engine.castServer = server
	return server, nil
}

const nativeCastDIDL = `urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/`

func nativeCastEscape(text string) string {
	var builder strings.Builder
	_ = xml.EscapeText(&builder, []byte(text))
	return builder.String()
}

func nativeCastContentType(address string) string {
	path := strings.ToLower(address)
	if index := strings.Index(path, "?"); index >= 0 {
		path = path[:index]
	}
	switch {
	case strings.HasSuffix(path, ".m3u8"):
		return "application/vnd.apple.mpegurl"
	case strings.HasSuffix(path, ".mp4"), strings.HasSuffix(path, ".m4v"):
		return "video/mp4"
	default:
		return "video/mp4"
	}
}

func nativeCastMetadata(title, address string) string {
	contentType := nativeCastContentType(address)
	return `<DIDL-Lite xmlns="` + nativeCastDIDL + `" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">` +
		`<item id="0" parentID="-1" restricted="1">` +
		`<dc:title>` + nativeCastEscape(title) + `</dc:title>` +
		`<upnp:class>object.item.videoItem</upnp:class>` +
		`<res protocolInfo="http-get:*:` + contentType + `:*">` + nativeCastEscape(address) + `</res>` +
		`</item></DIDL-Lite>`
}

func nativeCastSOAP(ctx context.Context, controlURL, serviceType, action string, arguments [][2]string) (string, error) {
	if controlURL == "" || serviceType == "" {
		return "", errors.New("投屏设备缺少控制接口")
	}
	var body strings.Builder
	body.WriteString(`<?xml version="1.0" encoding="utf-8"?>`)
	body.WriteString(`<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>`)
	body.WriteString("<u:" + action + ` xmlns:u="` + serviceType + `">`)
	for _, argument := range arguments {
		body.WriteString("<" + argument[0] + ">" + nativeCastEscape(argument[1]) + "</" + argument[0] + ">")
	}
	body.WriteString("</u:" + action + "></s:Body></s:Envelope>")
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, controlURL, strings.NewReader(body.String()))
	if err != nil {
		return "", errors.New("投屏设备地址无效")
	}
	request.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	request.Header.Set("SOAPACTION", `"`+serviceType+"#"+action+`"`)
	request.Header.Set("Connection", "close")
	client := &http.Client{Timeout: nativeCastProbe}
	response, err := client.Do(request)
	if err != nil {
		return "", errors.New("无法连接投屏设备，请确认电视与本机在同一网络")
	}
	defer response.Body.Close()
	payload, _ := io.ReadAll(io.LimitReader(response.Body, 128<<10))
	if response.StatusCode != http.StatusOK {
		return "", errors.New(nativeCastFault(string(payload)))
	}
	return string(payload), nil
}

func nativeCastFault(payload string) string {
	for _, tag := range []string{"errorDescription", "UPnPError"} {
		if value := nativeCastTag(payload, tag); value != "" {
			return "投屏设备返回错误：" + value
		}
	}
	return "投屏设备拒绝了本次操作"
}

func nativeCastTag(payload, tag string) string {
	open := "<" + tag + ">"
	start := strings.Index(payload, open)
	if start < 0 {
		return ""
	}
	start += len(open)
	end := strings.Index(payload[start:], "</"+tag+">")
	if end < 0 {
		return ""
	}
	return strings.TrimSpace(payload[start : start+end])
}

func nativeCastTarget(milliseconds int64) string {
	if milliseconds < 0 {
		milliseconds = 0
	}
	seconds := milliseconds / 1000
	return fmt.Sprintf("%02d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60)
}

func nativeCastMilliseconds(value string) int64 {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if index := strings.Index(value, "."); index >= 0 {
		value = value[:index]
	}
	parts := strings.Split(value, ":")
	if len(parts) == 0 || len(parts) > 3 {
		return 0
	}
	total := int64(0)
	for _, part := range parts {
		number, err := strconv.ParseInt(strings.TrimSpace(part), 10, 64)
		if err != nil || number < 0 {
			return 0
		}
		total = total*60 + number
	}
	return total * 1000
}

func (engine *nativeEngine) nativeCastCurrent() nativeCastSession {
	engine.castMu.Lock()
	defer engine.castMu.Unlock()
	if engine.castSession == nil {
		return nativeCastSession{}
	}
	return *engine.castSession
}

func (engine *nativeEngine) nativeCastStart(ctx context.Context, input nativeCastInput) (any, error) {
	device, err := engine.nativeCastDevice(input.Device)
	if err != nil {
		return nil, err
	}
	engine.mu.Lock()
	choice, exists := engine.playbacks[input.Session]
	engine.mu.Unlock()
	if !exists || choice.index < 0 || choice.index >= len(choice.media) {
		return nil, errors.New("播放线路已失效，请重新解析播放")
	}
	server, err := engine.nativeCastStreamServer()
	if err != nil {
		return nil, err
	}
	media := choice.media[choice.index]
	address, token := server.nativeOpen(media)
	title := strings.TrimSpace(input.Title)
	if title == "" {
		title = "短剧"
	}
	metadata := nativeCastMetadata(title, address)
	if _, err := nativeCastSOAP(ctx, device.ControlURL, device.ServiceType, "SetAVTransportURI", [][2]string{
		{"InstanceID", "0"}, {"CurrentURI", address}, {"CurrentURIMetaData", metadata},
	}); err != nil {
		server.nativeRelease(token)
		return nil, err
	}
	if _, err := nativeCastSOAP(ctx, device.ControlURL, device.ServiceType, "Play", [][2]string{
		{"InstanceID", "0"}, {"Speed", "1"},
	}); err != nil {
		server.nativeRelease(token)
		return nil, err
	}
	engine.castMu.Lock()
	previous := engine.castSession
	engine.castSession = &nativeCastSession{device: device, streamSession: token, session: input.Session, title: title, started: time.Now()}
	engine.castMu.Unlock()
	if previous != nil {
		if previous.streamSession != "" && previous.streamSession != token {
			server.nativeRelease(previous.streamSession)
		}
		if previous.device.ControlURL != device.ControlURL {
			_, _ = nativeCastSOAP(ctx, previous.device.ControlURL, previous.device.ServiceType, "Stop", [][2]string{{"InstanceID", "0"}})
		}
	}
	if input.TargetMS > 0 {
		_, _ = nativeCastSOAP(ctx, device.ControlURL, device.ServiceType, "Seek", [][2]string{
			{"InstanceID", "0"}, {"Unit", "REL_TIME"}, {"Target", nativeCastTarget(input.TargetMS)},
		})
	}
	return engine.nativeCastStatusPayload(ctx), nil
}

func (engine *nativeEngine) nativeCastStatusPayload(ctx context.Context) map[string]any {
	current := engine.nativeCastCurrent()
	result := map[string]any{"active": current.streamSession != ""}
	if current.streamSession == "" {
		return result
	}
	result["device"] = current.device.Name
	result["deviceId"] = current.device.ID
	result["title"] = current.title
	result["startedAt"] = current.started.UnixMilli()
	state := ""
	if payload, err := nativeCastSOAP(ctx, current.device.ControlURL, current.device.ServiceType, "GetTransportInfo", [][2]string{{"InstanceID", "0"}}); err == nil {
		state = nativeCastTag(payload, "CurrentTransportState")
	}
	if payload, err := nativeCastSOAP(ctx, current.device.ControlURL, current.device.ServiceType, "GetPositionInfo", [][2]string{{"InstanceID", "0"}}); err == nil {
		result["positionMs"] = nativeCastMilliseconds(nativeCastTag(payload, "RelTime"))
		result["durationMs"] = nativeCastMilliseconds(nativeCastTag(payload, "TrackDuration"))
	}
	result["state"] = state
	return result
}

func (engine *nativeEngine) nativeCastStop(ctx context.Context, silent bool) (any, error) {
	engine.castMu.Lock()
	current := engine.castSession
	server := engine.castServer
	engine.castSession = nil
	engine.castMu.Unlock()
	if current == nil {
		return map[string]any{"active": false}, nil
	}
	if !silent {
		_, _ = nativeCastSOAP(ctx, current.device.ControlURL, current.device.ServiceType, "Stop", [][2]string{{"InstanceID", "0"}})
	}
	if server != nil && current.streamSession != "" {
		server.nativeRelease(current.streamSession)
	}
	return map[string]any{"active": false}, nil
}

func (engine *nativeEngine) nativeCastTransport(ctx context.Context, action string) (any, error) {
	current := engine.nativeCastCurrent()
	if current.streamSession == "" {
		return nil, errors.New("当前没有进行中的投屏")
	}
	arguments := [][2]string{{"InstanceID", "0"}}
	if action == "Play" {
		arguments = append(arguments, [2]string{"Speed", "1"})
	}
	if _, err := nativeCastSOAP(ctx, current.device.ControlURL, current.device.ServiceType, action, arguments); err != nil {
		return nil, err
	}
	return engine.nativeCastStatusPayload(ctx), nil
}

func (engine *nativeEngine) nativeCastSeek(ctx context.Context, input nativeCastInput) (any, error) {
	current := engine.nativeCastCurrent()
	if current.streamSession == "" {
		return nil, errors.New("当前没有进行中的投屏")
	}
	unit := strings.TrimSpace(input.Unit)
	if unit != "ABS_TIME" {
		unit = "REL_TIME"
	}
	if _, err := nativeCastSOAP(ctx, current.device.ControlURL, current.device.ServiceType, "Seek", [][2]string{
		{"InstanceID", "0"}, {"Unit", unit}, {"Target", nativeCastTarget(input.TargetMS)},
	}); err != nil {
		return nil, err
	}
	return engine.nativeCastStatusPayload(ctx), nil
}

func (engine *nativeEngine) nativeCastVolume(ctx context.Context, input nativeCastInput) (any, error) {
	current := engine.nativeCastCurrent()
	if current.streamSession == "" {
		return nil, errors.New("当前没有进行中的投屏")
	}
	if current.device.RenderingControlURL == "" {
		return nil, errors.New("该设备不支持音量调节")
	}
	volume := input.Volume
	if volume < 0 {
		volume = 0
	}
	if volume > 100 {
		volume = 100
	}
	if _, err := nativeCastSOAP(ctx, current.device.RenderingControlURL, nativeCastRendering, "SetVolume", [][2]string{
		{"InstanceID", "0"}, {"Channel", "Master"}, {"DesiredVolume", strconv.Itoa(volume)},
	}); err != nil {
		return nil, err
	}
	return map[string]any{"volume": volume}, nil
}

func (engine *nativeEngine) nativeCast(ctx context.Context, command string, raw json.RawMessage) (any, error) {
	var input nativeCastInput
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &input); err != nil {
			return nil, errors.New("投屏请求无效")
		}
	}
	switch command {
	case "discover":
		return engine.nativeCastDiscover(ctx, input)
	case "start":
		return engine.nativeCastStart(ctx, input)
	case "stop":
		return engine.nativeCastStop(ctx, false)
	case "pause":
		return engine.nativeCastTransport(ctx, "Pause")
	case "resume":
		return engine.nativeCastTransport(ctx, "Play")
	case "seek":
		return engine.nativeCastSeek(ctx, input)
	case "volume":
		return engine.nativeCastVolume(ctx, input)
	case "status":
		return engine.nativeCastStatusPayload(ctx), nil
	default:
		return nil, errors.New("不支持的投屏操作")
	}
}
