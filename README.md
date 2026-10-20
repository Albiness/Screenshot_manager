# 📸 Smart Screenshot Manager

**A modern, offline-first screenshot capture and management application for Windows, built with Flutter.**

Smart Screenshot Manager brings screenshot capture, image annotation, text recognition (OCR), and screenshot organization together in one desktop application.

Instead of simply saving screenshots as image files, the application helps users manage their captures, extract useful information, and find previously saved screenshots through text search.

## ✨ Features

### 📷 Screenshot Capture
- Capture screenshots directly from Windows.
- Select a specific region of the screen.
- Support for full-screen capture.
- Keyboard shortcuts for faster access.
- Save screenshots as PNG images.

### ✏️ Screenshot Editor
The screenshot editing tools are designed to support:

- Freehand drawing.
- Lines, arrows, and rectangles.
- Text annotations.
- Highlighting and mosaic effects.
- Selecting areas of a screenshot.

*Editor tool availability may vary depending on the application version.*

### 🔍 OCR — Optical Character Recognition
- Extract text from screenshots.
- Use Windows OCR capabilities.
- Copy recognized text to the clipboard.
- Search for screenshots using recognized text.
- Process screenshots locally without requiring a cloud OCR service.

### 🗂️ Screenshot Management
- Local screenshot history.
- Screenshot previews.
- Search through recognized text.
- Mark important screenshots as favorites.
- Open saved screenshots and their folders.
- Delete screenshots that are no longer needed.
- Re-run OCR on saved screenshots.

### 🔒 Privacy & Offline Operation
Smart Screenshot Manager is designed around local processing.

- No cloud OCR API is required.
- Screenshot history is stored locally.
- No user account is required for the core workflow.
- Screenshot content does not need to be uploaded to an external server.

## 🛠️ Technology Stack

| Technology | Purpose |
|---|---|
| Flutter | Desktop application framework |
| Dart | Application programming language |
| Windows | Target operating system |
| SQLite | Local screenshot metadata and history |
| Windows OCR | Text recognition |
| Native Windows APIs | Screen capture and platform integration |

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl + Shift + S` | Start screenshot capture |
| `Ctrl + Alt + X` | Alternative capture shortcut, where supported |

*Shortcut registration and availability depend on the current build and Windows configuration.*

## 🚀 Getting Started

### Prerequisites

To build the application from source, you need:

- Windows 10 or Windows 11
- Flutter SDK with Windows desktop support
- Dart SDK (included with Flutter)
- Visual Studio with Desktop development with C++
- Git
- VS Code or another supported IDE

Check your Flutter environment:

```bash
flutter doctor
```

### Installation from Source

**1. Clone the repository**

```bash
git clone https://github.com/Albiness/Screenshot_manager.git
```

**2. Open the project directory**

```bash
cd Screenshot_manager
```

**3. Install dependencies**

```bash
flutter pub get
```

**4. Run the application**

```bash
flutter run -d windows
```

### Build a Release Version

To create a Windows release build:

```bash
flutter build windows --release
```

The compiled application will be available in:

```text
build/windows/x64/runner/Release/
```

The release application may require accompanying DLLs and data files from the build output directory.

## 📖 How It Works

**Step 1 — Capture**

Take a screenshot using the application interface or a configured keyboard shortcut.

**Step 2 — Select and Edit**

Choose the desired screen region and, where supported, add annotations using the built-in editing tools.

**Step 3 — Recognize Text**

The OCR component extracts text from the captured image.

**Step 4 — Save**

The screenshot is stored locally, with associated information maintained in the application's database.

**Step 5 — Search**

Find previous screenshots using recognized words or text fragments.

## 🏗️ Architecture

The application combines several core components:

```text
Smart Screenshot Manager
│
├── Flutter Desktop UI
│
├── Screenshot Capture
│   ├── Screen Capture
│   └── Region Selection
│
├── Image Editor
│   └── Annotation Tools
│
├── OCR Processing
│   └── Windows Text Recognition
│
├── Screenshot Management
│   ├── History
│   ├── Search
│   └── Favorites
│
└── Local Storage
    ├── SQLite Database
    └── Screenshot Files
```

*This diagram represents the logical application components rather than the exact source-code directory structure.*

## 🖼️ Screenshots

Application screenshots can be added here to demonstrate the user interface and features.

Suggested examples:

- Main application window
- Screenshot region selection
- Screenshot editor
- OCR text recognition
- Screenshot history and search

## 🧭 Future Improvements

Potential directions for further development include:

- Improved screenshot editing tools.
- More advanced search and filtering.
- Customizable keyboard shortcuts.
- Better multi-monitor support.
- Export and backup functionality.
- Screenshot organization using tags.
- Performance and memory optimizations.

These are development ideas, not a guarantee that every feature is currently available.

Built with Flutter and Dart for Windows.
