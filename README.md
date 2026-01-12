# macocr

A lightweight macOS Command Line Interface (CLI) tool for Optical Character Recognition (OCR), powered by the Apple Vision framework.

## Features

- **Native Performance:** Uses macOS's built-in `VNRecognizeTextRequest` for high-quality, hardware-accelerated OCR.
- **Fast/Accurate Modes:** Choose between speed and precision.
- **Simple Interface:** Easy-to-use CLI built with `swift-argument-parser`.

## Installation

### Prerequisites

- macOS 11.0 or later
- Swift 5.9+ (included with Xcode)

### Building from Source

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd macocr
   ```

2. Build the release binary:
   ```bash
   swift build -c release
   ```

3. (Optional) Install the binary to your path:
   ```bash
   cp .build/release/macocr /usr/local/bin/macocr
   ```

## Usage

Basic usage:
```bash
macocr path/to/image.jpg
```

Piping from stdin:
```bash
cat image.png | macocr
# or
curl -s https://example.com/image.png | macocr
```

### Options

- `--fast`, `-f`: Use the fast recognition level (less accurate but quicker).
- `--help`, `-h`: Show help information.

### Examples

Extract text from a screenshot:
```bash
macocr ~/Desktop/Screenshot.png
```

Extract text using the fast mode:
```bash
macocr --fast input.jpg
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
