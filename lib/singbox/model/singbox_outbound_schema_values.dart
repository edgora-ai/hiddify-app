// Shared dropdown candidates for sing-box outbound fields.
//
// Extracted from the values previously embedded in the JSON editor so both
// the JSON editor and the node form use a single source of truth.
// Pure Dart: no Flutter imports allowed here.

/// Protocols supported by the node form (v1).
const nodeFormProtocols = <String>['vmess', 'vless', 'trojan', 'shadowsocks', 'tuic', 'hysteria2'];

/// Transport types offered by the node form for vmess/vless/trojan.
/// NOTE: `tcp` means "no transport object" in sing-box; it must never be
/// written as `transport.type = tcp`.
const nodeTransportTypes = <String>['tcp', 'ws', 'grpc', 'httpupgrade'];

/// TLS mode selector options.
const nodeTlsModes = <String>['none', 'tls', 'reality'];

const nodeVmessSecurities = <String>['auto', 'none', 'zero', 'aes-128-gcm', 'chacha20-poly1305'];

const nodeVlessFlows = <String>['', 'xtls-rprx-vision'];

const nodePacketEncodings = <String>['', 'xudp', 'packetaddr'];

const nodeShadowsocksMethods = <String>[
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
  'none',
];

const nodeShadowsocksPlugins = <String>['', 'obfs-local', 'v2ray-plugin'];

const nodeMultiplexProtocols = <String>['smux', 'yamux', 'h2mux'];

const nodeUtlsFingerprints = <String>[
  'chrome',
  'firefox',
  'edge',
  'safari',
  'ios',
  'android',
  'random',
  'randomized',
  '360',
  'qq',
];

const nodeTuicCongestionControls = <String>['cubic', 'bbr', 'new_reno'];

const nodeTuicUdpRelayModes = <String>['native', 'quic'];

const nodeHysteria2ObfsTypes = <String>['', 'salamander'];
