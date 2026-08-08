//go:build windows

package killswitch

import (
	"encoding/binary"
	"fmt"
	"net"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	modfwpuclnt = windows.NewLazySystemDLL("fwpuclnt.dll")

	procFwpmEngineOpen0          = modfwpuclnt.NewProc("FwpmEngineOpen0")
	procFwpmEngineClose0         = modfwpuclnt.NewProc("FwpmEngineClose0")
	procFwpmSubLayerAdd0         = modfwpuclnt.NewProc("FwpmSubLayerAdd0")
	procFwpmSubLayerDeleteByKey0 = modfwpuclnt.NewProc("FwpmSubLayerDeleteByKey0")
	procFwpmFilterAdd0           = modfwpuclnt.NewProc("FwpmFilterAdd0")
)

type GUID struct {
	Data1 uint32
	Data2 uint16
	Data3 uint16
	Data4 [8]byte
}

type FWPM_DISPLAY_DATA0 struct {
	Name        *uint16
	Description *uint16
}

type FWPM_SESSION0 struct {
	SessionKey           GUID
	DisplayData          FWPM_DISPLAY_DATA0
	Flags                uint32
	TxnWaitTimeoutInMSec uint32
	ProcessId            uint32
	Sid                  uintptr
	Username             uintptr
	IsSystem             int32
}

type FWP_BYTE_BLOB struct {
	Size uint32
	Pad  uint32
	Data *byte
}

type FWPM_SUBLAYER0 struct {
	SubLayerKey  GUID
	DisplayData  FWPM_DISPLAY_DATA0
	Flags        uint32
	Pad          uint32
	ProviderKey  *GUID
	ProviderData FWP_BYTE_BLOB
	Weight       uint16
}

type FWP_VALUE0 struct {
	Type  uint32
	Pad   uint32
	Value uintptr
}

type FWP_V4_ADDR_AND_MASK struct {
	Addr uint32
	Mask uint32
}

type FWP_BYTE_ARRAY16 struct {
	ByteArray16 [16]byte
}

type FWPM_ACTION0 struct {
	Type       uint32
	FilterType GUID
}

type FWPM_FILTER_CONDITION0 struct {
	FieldKey       GUID
	MatchType      uint32
	Pad            uint32
	ConditionValue FWP_VALUE0
}

type FWPM_FILTER0 struct {
	FilterKey           GUID
	DisplayData         FWPM_DISPLAY_DATA0
	Flags               uint32
	Pad1                uint32
	ProviderKey         *GUID
	ProviderData        FWP_BYTE_BLOB
	LayerKey            GUID
	SubLayerKey         GUID
	Weight              FWP_VALUE0
	NumFilterConditions uint32
	Pad2                uint32
	FilterCondition     *FWPM_FILTER_CONDITION0
	Action              FWPM_ACTION0
	ContextPad          uint32
	Context             uint64
	Reserved            uintptr
	FilterId            uint64
	EffectiveWeight     FWP_VALUE0
}

const (
	RPC_C_AUTHN_WINNT        = 10
	FWPM_SESSION_FLAG_DYNAMIC = 0x00000001

	FWP_ACTION_BLOCK  = 0x00000001
	FWP_ACTION_PERMIT = 0x00000002

	FWP_MATCH_EQUAL = 0

	FWP_EMPTY             = 0
	FWP_UINT8             = 1
	FWP_UINT16            = 2
	FWP_UINT32            = 3
	FWP_UINT64            = 4
	FWP_BYTE_ARRAY16_TYPE = 12
	FWP_V4_ADDR_MASK      = 14
)

var (
	// WFP Layers
	FWPM_LAYER_ALE_AUTH_CONNECT_V4     = GUID{0x4a721c01, 0x5498, 0x429f, [8]byte{0x8b, 0x10, 0x1b, 0x22, 0xaa, 0x90, 0xbc, 0xd0}}
	FWPM_LAYER_ALE_AUTH_CONNECT_V6     = GUID{0x4a721c02, 0x5498, 0x429f, [8]byte{0x8b, 0x10, 0x1b, 0x22, 0xaa, 0x90, 0xbc, 0xd0}}
	FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4 = GUID{0x1b57604f, 0x0562, 0x4d53, [8]byte{0xa9, 0xc1, 0xe4, 0xf6, 0x50, 0xed, 0x8b, 0x84}}
	FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6 = GUID{0x1b576050, 0x0562, 0x4d53, [8]byte{0xa9, 0xc1, 0xe4, 0xf6, 0x50, 0xed, 0x8b, 0x84}}
	FWPM_LAYER_OUTBOUND_IPPACKET_V4    = GUID{0x12a95e0a, 0x47ec, 0x4896, [8]byte{0x80, 0xa1, 0x5b, 0x58, 0x76, 0x73, 0x82, 0x0a}}
	FWPM_LAYER_INBOUND_IPPACKET_V4     = GUID{0x12a95e0b, 0x47ec, 0x4896, [8]byte{0x80, 0xa1, 0x5b, 0x58, 0x76, 0x73, 0x82, 0x0b}}
	FWPM_LAYER_OUTBOUND_IPPACKET_V6    = GUID{0x12a95e0c, 0x47ec, 0x4896, [8]byte{0x80, 0xa1, 0x5b, 0x58, 0x76, 0x73, 0x82, 0x0c}}
	FWPM_LAYER_INBOUND_IPPACKET_V6     = GUID{0x12a95e0d, 0x47ec, 0x4896, [8]byte{0x80, 0xa1, 0x5b, 0x58, 0x76, 0x73, 0x82, 0x0d}}

	// WFP Conditions
	FWPM_CONDITION_IP_LOCAL_ADDRESS        = GUID{0x15354eb6, 0xa8f6, 0x4d8d, [8]byte{0x80, 0xb6, 0xfa, 0x3d, 0x6e, 0x2d, 0x56, 0xc9}}
	FWPM_CONDITION_IP_REMOTE_ADDRESS       = GUID{0x15354eb7, 0xa8f6, 0x4d8d, [8]byte{0x80, 0xb6, 0xfa, 0x3d, 0x6e, 0x2d, 0x56, 0xc9}}
	FWPM_CONDITION_IP_LOCAL_PORT          = GUID{0x0c1ba161, 0xef26, 0x497e, [8]byte{0xb3, 0x3d, 0x6b, 0xfc, 0x20, 0xd0, 0x05, 0x5b}}
	FWPM_CONDITION_IP_REMOTE_PORT         = GUID{0x0c1ba162, 0xef26, 0x497e, [8]byte{0xb3, 0x3d, 0x6b, 0xfc, 0x20, 0xd0, 0x05, 0x5b}}
	FWPM_CONDITION_IP_PROTOCOL            = GUID{0x3e1762c6, 0x9f5c, 0x4523, [8]byte{0xa9, 0x08, 0x5e, 0x01, 0xc6, 0x93, 0x90, 0x4a}}
	FWPM_CONDITION_IP_LOCAL_INTERFACE_INDEX  = GUID{0x6a0f6797, 0x573b, 0x4762, [8]byte{0xac, 0x76, 0x22, 0x22, 0xe4, 0xdc, 0xc1, 0x46}}

	// Sublayer key for MosaicVPN filters
	SubLayerMosaicVPN = GUID{0xa1b2c3d4, 0xe5f6, 0x4789, [8]byte{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0}}
)

type wfpKillSwitch struct {
	mu           sync.Mutex
	enabled      bool
	engineHandle uintptr
}

func newKillSwitch() KillSwitch {
	return NewWFP()
}

// NewWFP returns a new WFP-based Windows KillSwitch.
func NewWFP() KillSwitch {
	return &wfpKillSwitch{}
}

func (w *wfpKillSwitch) Enable(tunnelIface string, serverIP net.IP, allowedDNS []net.IP) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.enabled {
		_ = w.disableLocked()
	}

	sessionName, _ := windows.UTF16PtrFromString("MosaicVPN KillSwitch Session")
	session := FWPM_SESSION0{
		DisplayData: FWPM_DISPLAY_DATA0{
			Name: sessionName,
		},
		Flags: FWPM_SESSION_FLAG_DYNAMIC,
	}

	var handle uintptr
	r1, _, _ := procFwpmEngineOpen0.Call(
		0,
		uintptr(RPC_C_AUTHN_WINNT),
		0,
		uintptr(unsafe.Pointer(&session)),
		uintptr(unsafe.Pointer(&handle)),
	)
	if r1 != 0 {
		return fmt.Errorf("FwpmEngineOpen0 failed: win32 error %d", r1)
	}
	w.engineHandle = handle

	// Add sublayer for MosaicVPN
	sublayerName, _ := windows.UTF16PtrFromString("MosaicVPN SubLayer")
	sublayer := FWPM_SUBLAYER0{
		SubLayerKey: SubLayerMosaicVPN,
		DisplayData: FWPM_DISPLAY_DATA0{
			Name: sublayerName,
		},
		Weight: 0xFFFF,
	}
	r2, _, _ := procFwpmSubLayerAdd0.Call(
		w.engineHandle,
		uintptr(unsafe.Pointer(&sublayer)),
		0,
	)
	if r2 != 0 {
		w.disableLocked()
		return fmt.Errorf("FwpmSubLayerAdd0 failed: win32 error %d", r2)
	}

	// 1. Add block-all filters at low weight (0x100)
	blockLayers := []GUID{
		FWPM_LAYER_ALE_AUTH_CONNECT_V4,
		FWPM_LAYER_ALE_AUTH_CONNECT_V6,
		FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
		FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
		FWPM_LAYER_OUTBOUND_IPPACKET_V4,
		FWPM_LAYER_OUTBOUND_IPPACKET_V6,
	}
	for _, layer := range blockLayers {
		if err := w.addFilterLocked(layer, "MosaicVPN Block All", FWP_ACTION_BLOCK, 0x100, nil); err != nil {
			w.disableLocked()
			return fmt.Errorf("add block-all filter failed: %w", err)
		}
	}

	// 2. Permit VPN tunnel interface if specified
	if tunnelIface != "" {
		iface, err := net.InterfaceByName(tunnelIface)
		if err != nil {
			w.disableLocked()
			return fmt.Errorf("tunnel interface %q not found: %w", tunnelIface, err)
		}
		if iface.Index > 0 {
			ifIdx := uint32(iface.Index)
			condIdx := []FWPM_FILTER_CONDITION0{
				{
					FieldKey:  FWPM_CONDITION_IP_LOCAL_INTERFACE_INDEX,
					MatchType: FWP_MATCH_EQUAL,
					ConditionValue: FWP_VALUE0{
						Type:  FWP_UINT32,
						Value: uintptr(ifIdx),
					},
				},
			}
			permitIfaceLayers := []GUID{
				FWPM_LAYER_ALE_AUTH_CONNECT_V4,
				FWPM_LAYER_ALE_AUTH_CONNECT_V6,
				FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
				FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
				FWPM_LAYER_OUTBOUND_IPPACKET_V4,
				FWPM_LAYER_OUTBOUND_IPPACKET_V6,
				FWPM_LAYER_INBOUND_IPPACKET_V4,
				FWPM_LAYER_INBOUND_IPPACKET_V6,
			}
			for _, layer := range permitIfaceLayers {
				if err := w.addFilterLocked(layer, "MosaicVPN Permit Tunnel Interface", FWP_ACTION_PERMIT, 0x1000, condIdx); err != nil {
					w.disableLocked()
					return fmt.Errorf("add tunnel interface permit filter failed: %w", err)
				}
			}
		}
	}

	// 3. Permit VPN server IP (to establish tunnel)
	if len(serverIP) > 0 {
		if serverIP4 := serverIP.To4(); serverIP4 != nil {
			ipUint := binary.BigEndian.Uint32(serverIP4)
			condServer := []FWPM_FILTER_CONDITION0{
				{
					FieldKey:  FWPM_CONDITION_IP_REMOTE_ADDRESS,
					MatchType: FWP_MATCH_EQUAL,
					ConditionValue: FWP_VALUE0{
						Type:  FWP_UINT32,
						Value: uintptr(ipUint),
					},
				},
			}
			serverLayersV4 := []GUID{
				FWPM_LAYER_ALE_AUTH_CONNECT_V4,
				FWPM_LAYER_OUTBOUND_IPPACKET_V4,
			}
			for _, layer := range serverLayersV4 {
				if err := w.addFilterLocked(layer, "MosaicVPN Permit Server IP V4", FWP_ACTION_PERMIT, 0x1000, condServer); err != nil {
					w.disableLocked()
					return fmt.Errorf("add server IP V4 permit filter failed: %w", err)
				}
			}
		} else if serverIP16 := serverIP.To16(); serverIP16 != nil {
			var byteArray FWP_BYTE_ARRAY16
			copy(byteArray.ByteArray16[:], serverIP16)
			condServer := []FWPM_FILTER_CONDITION0{
				{
					FieldKey:  FWPM_CONDITION_IP_REMOTE_ADDRESS,
					MatchType: FWP_MATCH_EQUAL,
					ConditionValue: FWP_VALUE0{
						Type:  FWP_BYTE_ARRAY16_TYPE,
						Value: uintptr(unsafe.Pointer(&byteArray)),
					},
				},
			}
			serverLayersV6 := []GUID{
				FWPM_LAYER_ALE_AUTH_CONNECT_V6,
				FWPM_LAYER_OUTBOUND_IPPACKET_V6,
			}
			for _, layer := range serverLayersV6 {
				if err := w.addFilterLocked(layer, "MosaicVPN Permit Server IP V6", FWP_ACTION_PERMIT, 0x1000, condServer); err != nil {
					w.disableLocked()
					return fmt.Errorf("add server IP V6 permit filter failed: %w", err)
				}
			}
		}
	}

	// 4. Permit Loopback traffic (127.0.0.0/8 and ::1)
	v4LoopbackMask := FWP_V4_ADDR_AND_MASK{
		Addr: binary.BigEndian.Uint32(net.ParseIP("127.0.0.0").To4()),
		Mask: binary.BigEndian.Uint32(net.IP{255, 0, 0, 0}),
	}
	condLoopbackV4 := []FWPM_FILTER_CONDITION0{
		{
			FieldKey:  FWPM_CONDITION_IP_REMOTE_ADDRESS,
			MatchType: FWP_MATCH_EQUAL,
			ConditionValue: FWP_VALUE0{
				Type:  FWP_V4_ADDR_MASK,
				Value: uintptr(unsafe.Pointer(&v4LoopbackMask)),
			},
		},
	}
	loopbackLayersV4 := []GUID{
		FWPM_LAYER_ALE_AUTH_CONNECT_V4,
		FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
		FWPM_LAYER_OUTBOUND_IPPACKET_V4,
		FWPM_LAYER_INBOUND_IPPACKET_V4,
	}
	for _, layer := range loopbackLayersV4 {
		if err := w.addFilterLocked(layer, "MosaicVPN Permit Loopback V4", FWP_ACTION_PERMIT, 0x1000, condLoopbackV4); err != nil {
			w.disableLocked()
			return fmt.Errorf("add loopback V4 permit filter failed: %w", err)
		}
	}

	var v6LoopbackByteArray FWP_BYTE_ARRAY16
	copy(v6LoopbackByteArray.ByteArray16[:], net.ParseIP("::1").To16())
	condLoopbackV6 := []FWPM_FILTER_CONDITION0{
		{
			FieldKey:  FWPM_CONDITION_IP_REMOTE_ADDRESS,
			MatchType: FWP_MATCH_EQUAL,
			ConditionValue: FWP_VALUE0{
				Type:  FWP_BYTE_ARRAY16_TYPE,
				Value: uintptr(unsafe.Pointer(&v6LoopbackByteArray)),
			},
		},
	}
	loopbackLayersV6 := []GUID{
		FWPM_LAYER_ALE_AUTH_CONNECT_V6,
		FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
		FWPM_LAYER_OUTBOUND_IPPACKET_V6,
		FWPM_LAYER_INBOUND_IPPACKET_V6,
	}
	for _, layer := range loopbackLayersV6 {
		if err := w.addFilterLocked(layer, "MosaicVPN Permit Loopback V6", FWP_ACTION_PERMIT, 0x1000, condLoopbackV6); err != nil {
			w.disableLocked()
			return fmt.Errorf("add loopback V6 permit filter failed: %w", err)
		}
	}

	// 5. Permit DHCP (UDP ports 67 and 68)
	dhcpPorts := []struct {
		field GUID
		port  uint16
	}{
		{FWPM_CONDITION_IP_REMOTE_PORT, 67},
		{FWPM_CONDITION_IP_REMOTE_PORT, 68},
		{FWPM_CONDITION_IP_LOCAL_PORT, 68},
		{FWPM_CONDITION_IP_LOCAL_PORT, 67},
	}
	protoUDP := uint8(17)
	dhcpLayers := []GUID{
		FWPM_LAYER_ALE_AUTH_CONNECT_V4,
		FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
		FWPM_LAYER_OUTBOUND_IPPACKET_V4,
		FWPM_LAYER_INBOUND_IPPACKET_V4,
	}
	for _, dp := range dhcpPorts {
		condDHCP := []FWPM_FILTER_CONDITION0{
			{
				FieldKey:  FWPM_CONDITION_IP_PROTOCOL,
				MatchType: FWP_MATCH_EQUAL,
				ConditionValue: FWP_VALUE0{
					Type:  FWP_UINT8,
					Value: uintptr(protoUDP),
				},
			},
			{
				FieldKey:  dp.field,
				MatchType: FWP_MATCH_EQUAL,
				ConditionValue: FWP_VALUE0{
					Type:  FWP_UINT16,
					Value: uintptr(dp.port),
				},
			},
		}
		for _, layer := range dhcpLayers {
			if err := w.addFilterLocked(layer, "MosaicVPN Permit DHCP", FWP_ACTION_PERMIT, 0x1000, condDHCP); err != nil {
				w.disableLocked()
				return fmt.Errorf("add DHCP permit filter failed: %w", err)
			}
		}
	}

	// 6. Permit DNS to configured DNS servers only
	dnsPort := uint16(53)
	protoTCP := uint8(6)
	for _, dnsIP := range allowedDNS {
		if dnsIP4 := dnsIP.To4(); dnsIP4 != nil {
			ipUint := binary.BigEndian.Uint32(dnsIP4)
			for _, proto := range []uint8{protoUDP, protoTCP} {
				condDNS := []FWPM_FILTER_CONDITION0{
					{
						FieldKey:  FWPM_CONDITION_IP_PROTOCOL,
						MatchType: FWP_MATCH_EQUAL,
						ConditionValue: FWP_VALUE0{
							Type:  FWP_UINT8,
							Value: uintptr(proto),
						},
					},
					{
						FieldKey:  FWPM_CONDITION_IP_REMOTE_PORT,
						MatchType: FWP_MATCH_EQUAL,
						ConditionValue: FWP_VALUE0{
							Type:  FWP_UINT16,
							Value: uintptr(dnsPort),
						},
					},
					{
						FieldKey:  FWPM_CONDITION_IP_REMOTE_ADDRESS,
						MatchType: FWP_MATCH_EQUAL,
						ConditionValue: FWP_VALUE0{
							Type:  FWP_UINT32,
							Value: uintptr(ipUint),
						},
					},
				}
				dnsLayersV4 := []GUID{
					FWPM_LAYER_ALE_AUTH_CONNECT_V4,
					FWPM_LAYER_OUTBOUND_IPPACKET_V4,
				}
				for _, layer := range dnsLayersV4 {
					if err := w.addFilterLocked(layer, "MosaicVPN Permit DNS V4", FWP_ACTION_PERMIT, 0x1000, condDNS); err != nil {
						w.disableLocked()
						return fmt.Errorf("add DNS V4 permit filter failed: %w", err)
					}
				}
			}
		} else if dnsIP16 := dnsIP.To16(); dnsIP16 != nil {
			var byteArray FWP_BYTE_ARRAY16
			copy(byteArray.ByteArray16[:], dnsIP16)
			for _, proto := range []uint8{protoUDP, protoTCP} {
				condDNS := []FWPM_FILTER_CONDITION0{
					{
						FieldKey:  FWPM_CONDITION_IP_PROTOCOL,
						MatchType: FWP_MATCH_EQUAL,
						ConditionValue: FWP_VALUE0{
							Type:  FWP_UINT8,
							Value: uintptr(proto),
						},
					},
					{
						FieldKey:  FWPM_CONDITION_IP_REMOTE_PORT,
						MatchType: FWP_MATCH_EQUAL,
						ConditionValue: FWP_VALUE0{
							Type:  FWP_UINT16,
							Value: uintptr(dnsPort),
						},
					},
					{
						FieldKey:  FWPM_CONDITION_IP_REMOTE_ADDRESS,
						MatchType: FWP_MATCH_EQUAL,
						ConditionValue: FWP_VALUE0{
							Type:  FWP_BYTE_ARRAY16_TYPE,
							Value: uintptr(unsafe.Pointer(&byteArray)),
						},
					},
				}
				dnsLayersV6 := []GUID{
					FWPM_LAYER_ALE_AUTH_CONNECT_V6,
					FWPM_LAYER_OUTBOUND_IPPACKET_V6,
				}
				for _, layer := range dnsLayersV6 {
					if err := w.addFilterLocked(layer, "MosaicVPN Permit DNS V6", FWP_ACTION_PERMIT, 0x1000, condDNS); err != nil {
						w.disableLocked()
						return fmt.Errorf("add DNS V6 permit filter failed: %w", err)
					}
				}
			}
		}
	}

	w.enabled = true
	return nil
}

func (w *wfpKillSwitch) addFilterLocked(layerKey GUID, name string, actionType uint32, weight uint64, conditions []FWPM_FILTER_CONDITION0) error {
	filterName, _ := windows.UTF16PtrFromString(name)
	filter := FWPM_FILTER0{
		DisplayData: FWPM_DISPLAY_DATA0{
			Name: filterName,
		},
		LayerKey:    layerKey,
		SubLayerKey: SubLayerMosaicVPN,
		Weight: FWP_VALUE0{
			Type:  FWP_UINT64,
			Value: uintptr(unsafe.Pointer(&weight)),
		},
		Action: FWPM_ACTION0{
			Type: actionType,
		},
	}
	if len(conditions) > 0 {
		filter.NumFilterConditions = uint32(len(conditions))
		filter.FilterCondition = &conditions[0]
	}

	var filterID uint64
	r, _, _ := procFwpmFilterAdd0.Call(
		w.engineHandle,
		uintptr(unsafe.Pointer(&filter)),
		0,
		uintptr(unsafe.Pointer(&filterID)),
	)
	if r != 0 {
		return fmt.Errorf("FwpmFilterAdd0(%s) failed: win32 error %d", name, r)
	}
	return nil
}

func (w *wfpKillSwitch) Disable() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.disableLocked()
}

func (w *wfpKillSwitch) disableLocked() error {
	if w.engineHandle != 0 {
		procFwpmSubLayerDeleteByKey0.Call(
			w.engineHandle,
			uintptr(unsafe.Pointer(&SubLayerMosaicVPN)),
		)
		procFwpmEngineClose0.Call(w.engineHandle)
		w.engineHandle = 0
	}
	w.enabled = false
	return nil
}

func (w *wfpKillSwitch) IsEnabled() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.enabled
}
