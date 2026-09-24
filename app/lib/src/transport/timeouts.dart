/// Socket connect / SSH handshake budget.
const Duration kConnectTimeout = Duration(seconds: 10);

/// Budget for a buffered request (applied in DockerApiClient).
const Duration kRequestTimeout = Duration(seconds: 30);

/// Budget for a stream's response headers to arrive (applied in transports).
/// Stream bodies never time out.
const Duration kStreamHeaderTimeout = Duration(seconds: 30);
