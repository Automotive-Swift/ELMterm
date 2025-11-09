# ELMterm

A modern, intelligent terminal for automotive diagnostics that understands OBD-II, UDS, and KWP protocols.

## About the Name

ELM Electronics (now defunct) was the first company to create an affordable OBD-II to UART converter. Unfortunately, they released their first version on an unprotected MCU, and the market has been flooded with cheap clones ever since. The ELM327 protocol has become the de facto standard for consumer-grade automotive diagnostics, which is why this terminal bears the "ELM" name.

## Why ELMterm?

Traditional tools like `nc`, `picocom`, or `telnet` are caveman's tools when working with automotive adapters—they blindly pass bytes without understanding the protocols. **ELMterm is different.**

### The Problem with Basic Tools

When you use `nc` or `telnet` to connect to an ELM327 adapter, you see raw hex responses like:
```
7E8 10 14 49 02 01 57 41 55
7E8 21 5A 5A 5A 38 54 38 42
7E8 22 41 30 33 34 33 37 34
```

You're left to manually:
- Decode ISO-TP multi-frame messages
- Look up what service IDs mean
- Distinguish between OBD-II and UDS protocols
- Parse Negative Response Codes (NRCs)
- Figure out CAN header formats

### The ELMterm Advantage

ELMterm **understands** automotive protocols and provides real-time intelligence:

```
> 0902
0902
→ OBD-II request (mode 09)
    Hex: 09 02
    Request vehicle information
    PID 02
7E8 10 14 49 02 01 57 41 55
→ 📦 ISO-TP First Frame (1/20 bytes)
    Hex: 10 14 49 02 01 57 41 55
    Multi-frame message started, waiting for consecutive frames...
7E8 21 5A 5A 5A 38 54 38 42
→ 📦 ISO-TP Consecutive Frame (14/20 bytes)
    Hex: 21 5A 5A 5A 38 54 38 42
    Sequence 1, waiting for more frames...
7E8 22 41 30 33 34 33 37 34
→ ✅ ISO-TP: VIN Response
    Hex: 49 02 01 57 41 55 5A 5A 5A 38 54 38 42 41 30 33 34 33 37 34
    ASCII: I..WAUZZZ8T8BA034374
    Vehicle Identification Number (VIN): WAUZZZ8T8BA034374
```

## Features

### Protocol Intelligence

- **Real-time Protocol Annotation**: Every request and response is automatically analyzed and annotated with semantic meaning
- **OBD-II vs UDS/KWP Detection**: Automatically distinguishes between OBD-II (modes 01-0F) and UDS/KWP (modes 10+) protocols
- **ISO-TP Reassembly**: Automatically detects and reassembles multi-frame ISO 15765-2 messages with sequence validation
- **NRC Decoding**: Comprehensive Negative Response Code (ISO 14229-1:2020) descriptions with 50+ error codes
- **VIN Extraction**: Automatically decodes Vehicle Identification Numbers from mode 09 PID 02 responses
- **CAN Header Handling**: Intelligently strips variable-length CAN headers (11-bit and 29-bit)
- **ASCII Representation**: Shows readable ASCII for long hex responses

### Terminal Features

- **Readline-Style Editing**: Full cursor movement, character insertion/deletion
- **Command History**: Navigate previous commands with arrow keys (↑/↓)
- **Proper CR/LF Handling**: Clean display without text concatenation or stray characters
- **ELM327/STN Command Recognition**: Built-in hints and descriptions for AT/ST commands
- **Color-Coded Output**: Distinguishes incoming, outgoing, and status messages with readable colors

### Supported Protocols

- **OBD-II** (SAE J1979)
  - Mode 01: Show current data
  - Mode 02: Show freeze frame data
  - Mode 03: Show stored DTCs
  - Mode 04: Clear DTCs
  - Mode 09: Request vehicle information (VIN, calibration IDs, etc.)
  - And more...

- **UDS** (ISO 14229)
  - Diagnostic session control (0x10)
  - ECU reset (0x11)
  - Read data by identifier (0x22)
  - Security access (0x27)
  - Communication control (0x28)
  - Routine control (0x31)
  - And more...

- **ISO-TP** (ISO 15765-2)
  - Single frame
  - First frame + consecutive frames
  - Automatic sequence validation
  - Message reassembly

## Installation

### Prerequisites

- macOS 13 or later
- Swift 6.2 or later
- Xcode command-line tools

### Building

```bash
git clone <repository-url>
cd ELMterm
swift build -c release
```

The executable will be at `.build/release/ELMterm`.

## Usage

### Basic Connection

```bash
# Connect to ELM327 via USB serial
ELMterm tty://dummy:115200/dev/cu.usbserial-A12345

# Connect via network (if your adapter supports it)
ELMterm tcp://192.168.0.10:35000
```

### Command-Line Options

```
USAGE: ELMterm <url> [--annotation-disabled]

ARGUMENTS:
  <url>                   Connection URL (tty://dummy:BAUDRATE/PATH or tcp://HOST:PORT)

OPTIONS:
  --annotation-disabled   Disable protocol annotations
  -h, --help              Show help information
```

### Meta Commands

ELMterm supports meta commands prefixed with `:`:

- `:help` - Display help information
- `:quit` - Exit the terminal
- `:history` - Show command history
- `:annotations on|off` - Toggle protocol annotations

### Example Session

```bash
$ ELMterm tty://dummy:115200/dev/cu.usbserial-113010893810

> ati
ati
→ ELM adapter command ATI
    Adapter identification
ELM327 v1.4b

> 0100
0100
→ OBD-II request (mode 01)
    Hex: 01 00
    Show current data
    PID 00
7E8 41 00 BE 1F A8 13
→ OBD-II response
    Hex: 41 00 BE 1F A8 13
    ASCII: A.....
    Mode 01: Show current data

> 0902
0902
→ OBD-II request (mode 09)
    Hex: 09 02
    Request vehicle information
    PID 02
7E8 10 14 49 02 01 57 41 55
→ 📦 ISO-TP First Frame (1/20 bytes)
    ...
✅ ISO-TP: VIN Response
    Vehicle Identification Number (VIN): WAUZZZ8T8BA034374

> 1003
1003
→ UDS/KWP request (mode 10)
    Hex: 10 03
    Diagnostic session control
7E8 7F 10 12
→ ❌ Negative Response (NRC 0x12)
    Service 0x10 failed
    Sub-function not supported
    Hex: 7F 10 12
    ASCII: ...

> :quit
```

## Technical Details

### Protocol Detection

ELMterm uses intelligent heuristics to detect protocols:

1. **CAN Header Stripping**: Recognizes 3-digit (7E8, 7DF) and 8-digit (18DAF110) CAN IDs
2. **ISO-TP Frame Type**: Detects frame types by examining upper nibble (0x0-0x3)
3. **Service ID Analysis**: Distinguishes OBD-II (0x01-0x0F) from UDS (0x10+)
4. **Response Pairing**: Automatically pairs requests with responses for context

### ISO-TP Implementation

The ISO-TP reassembly engine:
- Detects First Frame (0x1X) and extracts total message length (12-bit)
- Buffers data from consecutive frames (0x2X) with sequence numbers 0-15
- Validates sequence continuity and reports errors
- Automatically decodes complete messages once all frames are received

### Color Scheme

- **Outgoing messages** (your commands): Blue
- **Incoming messages** (adapter responses): Dark gray
- **Status messages** (connection info): Magenta
- **Annotations** (protocol analysis): Dimmed color matching message direction

## Troubleshooting

### No response from adapter

```bash
> ati
NO DATA
→ Adapter status
    No ECU replied to this request
```

If you see "NO DATA", check:
1. Adapter is properly connected to vehicle OBD-II port
2. Vehicle ignition is on
3. Try `ATZ` to reset the adapter
4. Try `ATSP0` for automatic protocol detection

### Garbled output

If you see garbled output, ensure:
1. Correct baud rate (typically 115200 for USB, 38400 for Bluetooth)
2. Adapter echo is disabled: `ATE0`
3. Spaces are enabled for readability: `ATS1`
4. Headers are shown: `ATH1`

## Development

### Project Structure

```
ELMterm/
├── Sources/
│   └── ELMterm/
│       └── ELMterm.swift      # Main application
├── Package.swift              # Swift package manifest
├── README.md
└── LICENSE
```

### Dependencies

- [CornucopiaStreams](https://github.com/Cornucopia-Swift/CornucopiaStreams) - Stream handling (TTY/TCP)
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) - Command-line parsing

## Contributing

Contributions are welcome! Areas for improvement:

- Additional OBD-II PID decoders
- More UDS service implementations
- Support for other adapter types (STN, OBDLink, etc.)
- Network protocol support (Wi-Fi adapters)
- Configuration file support

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

- Based on ELM327 AT Command set
- ISO 14229-1:2020 (UDS) specification
- ISO 15765-2 (ISO-TP) specification
- SAE J1979 (OBD-II) standard

## See Also

- [ELM327 Datasheet](https://www.elmelectronics.com/wp-content/uploads/2016/07/ELM327DS.pdf)
- [ISO 14229-1 UDS Specification](https://www.iso.org/standard/72439.html)
- [SAE J1979 OBD-II Standard](https://www.sae.org/standards/content/j1979_202104/)
