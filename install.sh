#!/bin/bash
# Comprehensive Speech-to-Text Installer
# Supports both X11 and Wayland, checks all dependencies

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   log_error "Don't run this script as root!"
   exit 1
fi

echo "🎤 NVIDIA Canary Speech-to-Text Comprehensive Installer"
echo "======================================================"

# Step 1: Check Python version
log_info "Checking Python version..."
PYTHON_CMD=""
MIN_PYTHON_VERSION="3.11"

# Try different Python commands
for cmd in python3.12 python3.11 python3; do
    if command -v "$cmd" >/dev/null 2>&1; then
        PYTHON_VERSION=$($cmd --version 2>&1 | cut -d' ' -f2)
        PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d'.' -f1)
        PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d'.' -f2)
        
        if [[ $PYTHON_MAJOR -eq 3 ]] && [[ $PYTHON_MINOR -ge 11 ]] && [[ $PYTHON_MINOR -le 12 ]]; then
            PYTHON_CMD="$cmd"
            log_success "Found compatible Python: $cmd ($PYTHON_VERSION)"
            break
        fi
    fi
done

if [[ -z "$PYTHON_CMD" ]]; then
    log_error "No compatible Python found! Need Python 3.11 or 3.12"
    log_info "Install with: sudo apt install python3.12 python3.12-venv python3.12-dev"
    exit 1
fi

# Step 2: Check NVIDIA GPU and drivers
log_info "Checking NVIDIA GPU and drivers..."
GPU_AVAILABLE=false
CUDA_VERSION=""

if lspci | grep -i nvidia >/dev/null; then
    GPU_NAME=$(lspci | grep -i nvidia | head -n1 | cut -d':' -f3 | xargs)
    log_success "NVIDIA GPU detected: $GPU_NAME"
    
    if command -v nvidia-smi >/dev/null 2>&1; then
        DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n1)
        CUDA_VERSION=$(nvidia-smi | grep "CUDA Version" | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p')
        log_success "NVIDIA drivers installed: $DRIVER_VERSION (CUDA $CUDA_VERSION)"
        GPU_AVAILABLE=true
    else
        log_warning "NVIDIA GPU found but drivers not installed"
        log_info "Install drivers with: sudo ubuntu-drivers autoinstall && sudo reboot"
        
        read -p "Continue without GPU acceleration? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Please install NVIDIA drivers and re-run this script"
            exit 1
        fi
    fi
else
    log_warning "No NVIDIA GPU detected. Will use CPU-only mode."
fi

# Step 3: Install system dependencies
log_info "Installing system dependencies..."

# Update package list
sudo apt update

# Install essential packages
PACKAGES=(
    "build-essential"
    "portaudio19-dev"
    "pulseaudio-utils"
    "libnotify-bin"
    "python3-venv"
    "python3-dev"
    "python3-pip"
    "git"
    "curl"
    "wget"
)

# Display server specific packages
DISPLAY_SERVER="${XDG_SESSION_TYPE:-x11}"
log_info "Display server detected: $DISPLAY_SERVER"

if [[ "$DISPLAY_SERVER" == "wayland" ]]; then
    log_info "Installing Wayland tools (primary) + X11 tools (fallback)..."
    PACKAGES+=(
        "wtype"
        "ydotool"  
        "wl-clipboard"
        "xdotool"
        "xclip"
    )
else
    log_info "Installing X11 tools (primary) + Wayland tools (fallback)..."
    PACKAGES+=(
        "xdotool"
        "xclip"
        "wtype"
        "ydotool"
        "wl-clipboard"
    )
fi

# Install packages
log_info "Installing: ${PACKAGES[*]}"
sudo apt install -y "${PACKAGES[@]}"

# Configure ydotool for Wayland support
if command -v ydotool >/dev/null 2>&1; then
    log_info "Configuring ydotool..."
    sudo systemctl enable --now ydotoold 2>/dev/null || log_warning "ydotoold setup skipped"
    sudo usermod -a -G input "$USER" 2>/dev/null || log_warning "input group assignment skipped"
fi

# Step 4: Set up project directory
if [ "$(basename "$PWD")" == "speech-to-text" ] && [ -f "install.sh" ]; then
    # We're already in the project directory (likely from git clone)
    PROJECT_DIR="$PWD"
    log_info "Using current directory as project: $PROJECT_DIR"
else
    # Create project directory in home
    PROJECT_DIR="$HOME/speech-to-text"
    log_info "Creating project directory: $PROJECT_DIR"
    
    if [[ -d "$PROJECT_DIR" ]]; then
        log_warning "Project directory exists. Continuing..."
    else
        mkdir -p "$PROJECT_DIR"
    fi
    
    cd "$PROJECT_DIR"
fi

# Step 5: Setup Python virtual environment
EXISTING_VENV=false
if [[ -d "venv" ]] && [[ -f "venv/bin/activate" ]]; then
    log_info "Existing virtual environment found, checking compatibility..."
    source venv/bin/activate
    
    # Check if the Python version in venv matches our requirements
    VENV_PYTHON_VERSION=$(python --version 2>&1 | cut -d' ' -f2)
    VENV_MAJOR=$(echo $VENV_PYTHON_VERSION | cut -d'.' -f1)
    VENV_MINOR=$(echo $VENV_PYTHON_VERSION | cut -d'.' -f2)
    
    if [[ $VENV_MAJOR -eq 3 ]] && [[ $VENV_MINOR -ge 11 ]] && [[ $VENV_MINOR -le 12 ]]; then
        log_success "Compatible virtual environment found (Python $VENV_PYTHON_VERSION)"
        EXISTING_VENV=true
    else
        log_warning "Incompatible Python version in venv ($VENV_PYTHON_VERSION), recreating..."
        deactivate 2>/dev/null || true
        rm -rf venv
    fi
fi

if [[ "$EXISTING_VENV" == false ]]; then
    log_info "Creating new Python virtual environment..."
    $PYTHON_CMD -m venv venv
    source venv/bin/activate
    
    # Upgrade pip
    log_info "Upgrading pip..."
    pip install --upgrade pip
else
    log_info "Using existing virtual environment"
fi

# Step 6: Install PyTorch
PYTORCH_INSTALLED=false
if python -c "import torch; print('PyTorch version:', torch.__version__)" 2>/dev/null; then
    log_success "PyTorch already installed"
    PYTORCH_INSTALLED=true
else
    log_info "Installing PyTorch..."
fi

if [[ "$PYTORCH_INSTALLED" == false ]]; then
    if [[ "$GPU_AVAILABLE" == true ]]; then
        # Determine CUDA version for PyTorch
        CUDA_MAJOR=$(echo $CUDA_VERSION | cut -d'.' -f1)
        CUDA_MINOR=$(echo $CUDA_VERSION | cut -d'.' -f2)
        
        if [[ $CUDA_MAJOR -ge 12 ]]; then
            TORCH_CUDA="cu121"
            log_info "Installing PyTorch with CUDA 12.1 support..."
            # Install specific compatible versions for CUDA 12.1
            pip install torch==2.4.1+cu121 torchaudio==2.4.1+cu121 torchvision==0.19.1+cu121 --index-url "https://download.pytorch.org/whl/cu121"
        elif [[ $CUDA_MAJOR -eq 11 ]]; then
            TORCH_CUDA="cu118"  
            log_info "Installing PyTorch with CUDA 11.8 support..."
            # Install specific compatible versions for CUDA 11.8
            pip install torch==2.4.1+cu118 torchaudio==2.4.1+cu118 torchvision==0.19.1+cu118 --index-url "https://download.pytorch.org/whl/cu118"
        else
            TORCH_CUDA=""
            log_warning "Unsupported CUDA version, installing CPU-only PyTorch"
            # Install specific compatible CPU versions
            pip install torch==2.4.1 torchaudio==2.4.1 torchvision==0.19.1 --index-url "https://download.pytorch.org/whl/cpu"
        fi
    else
        log_info "Installing CPU-only PyTorch..."
        # Install specific compatible CPU versions
        pip install torch==2.4.1 torchaudio==2.4.1 torchvision==0.19.1 --index-url "https://download.pytorch.org/whl/cpu"
    fi
fi

# Step 7: Test PyTorch installation
log_info "Testing PyTorch installation..."
python -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU device: {torch.cuda.get_device_name(0)}')
    print(f'GPU memory: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB')
else:
    print('Running in CPU mode')
" || {
    log_error "PyTorch test failed!"
    exit 1
}

log_success "PyTorch installation successful!"

# Step 8: Install other Python dependencies
log_info "Installing Python dependencies..."

# Check and install basic dependencies
DEPS_TO_INSTALL=()
for dep in "numpy" "soundfile" "librosa" "pyaudio" "pynput"; do
    if ! python -c "import $dep" 2>/dev/null; then
        DEPS_TO_INSTALL+=("$dep")
    else
        log_success "$dep already installed"
    fi
done

if [[ ${#DEPS_TO_INSTALL[@]} -gt 0 ]]; then
    log_info "Installing missing dependencies: ${DEPS_TO_INSTALL[*]}"
    pip install "${DEPS_TO_INSTALL[@]}"
else
    log_success "All basic dependencies already installed"
fi

# Step 9: Install NeMo Toolkit
NEMO_INSTALLED=false
if python -c "import nemo.collections.speechlm; print('NeMo Toolkit available')" 2>/dev/null; then
    log_success "NeMo Toolkit already installed and functional"
    NEMO_INSTALLED=true
else
    log_info "Installing NVIDIA NeMo Toolkit (this may take a while)..."
fi

if [[ "$NEMO_INSTALLED" == false ]]; then
    # Install NeMo with all required components for speech-language models
    log_info "Installing NeMo with speech-language model support..."
    
    # Install nemo-run dependency first (required for NeMo 2.3.2+)
    log_info "Installing nemo-run dependency..."
    pip install nemo-run
    
    # Install specific compatible NeMo version
    log_info "Installing NeMo Toolkit 2.3.2..."
    if ! pip install "nemo_toolkit[all]==2.3.2"; then
        log_warning "Specific version install failed, trying latest with all components..."
        
        # Try with current latest version
        if ! pip install "nemo_toolkit[all]"; then
            log_warning "Full NeMo install failed, trying git installation..."
            
            # Try installing from git
            if ! pip install "git+https://github.com/NVIDIA/NeMo.git@main"; then
                log_error "All NeMo installation methods failed!"
                log_info "You may need to install NeMo manually:"
                log_info "pip install 'nemo_toolkit[all]' or pip install 'git+https://github.com/NVIDIA/NeMo.git'"
                exit 1
            fi
        fi
    fi
    
    # Install additional dependencies
    log_info "Installing additional NeMo dependencies..."
    pip install transformers datasets sentencepiece
    
    # Verify the installation includes speechlm (not speechlm2 in newer versions)
    log_info "Verifying NeMo speechlm module..."
    if ! python -c "import nemo.collections.speechlm; print('✅ speechlm module available')" 2>/dev/null; then
        log_error "speechlm module not available after installation"
        log_info "This might be a version compatibility issue"
        log_info "Try running: pip install 'git+https://github.com/NVIDIA/NeMo.git@main'"
    else
        log_success "NeMo speechlm module loaded successfully"
    fi
fi

# Step 10: Create launcher script
log_info "Creating launcher script..."
cat > run_speech_service.sh << 'EOF'
#!/bin/bash
# Speech-to-Text Service Launcher

cd "$(dirname "$0")"

# Check if virtual environment exists
if [ ! -d "venv" ]; then
    echo "❌ Virtual environment not found!"
    echo "Run install.sh first"
    exit 1
fi

# Activate virtual environment
source venv/bin/activate

# Set display environment
export DISPLAY=${DISPLAY:-:0}

# Run the hotkey service
echo "🎤 Starting Speech-to-Text Hotkey Service..."
echo "Press Super+P and hold to record, release to transcribe"
echo "Press Ctrl+C to quit"
echo ""

python speech_hotkey.py
EOF

chmod +x run_speech_service.sh

# Step 11: Verify required files exist

# Step 11: Verify required files exist
log_info "Verifying required Python scripts..."

# Check if the required files exist in the current directory
if [ ! -f "speech_to_text.py" ] || [ ! -f "speech_hotkey.py" ]; then
    log_error "Required Python scripts not found!"
    log_info "Make sure you're running this script from the cloned repository directory"
    log_info "Expected files: speech_to_text.py and speech_hotkey.py"
    exit 1
fi

log_success "Required Python scripts found"
chmod +x speech_to_text.py speech_hotkey.py

# Step 12: Test installation
log_info "Testing complete installation..."

# Create test script
cat > test_installation.py << 'EOF'
#!/usr/bin/env python3
import sys
import os
import subprocess

def test_imports():
    """Test all required imports"""
    try:
        import torch
        import soundfile
        import pyaudio  
        import pynput
        import tempfile
        import subprocess
        
        print("✅ All Python packages imported successfully")
        
        # Test PyTorch CUDA
        if torch.cuda.is_available():
            print(f"✅ CUDA available: {torch.cuda.get_device_name(0)}")
        else:
            print("ℹ️  CUDA not available, using CPU")
            
        return True
    except ImportError as e:
        print(f"❌ Import error: {e}")
        return False

def test_system_tools():
    """Test system tools availability"""
    display_server = os.environ.get('XDG_SESSION_TYPE', 'x11')
    
    tools_to_test = []
    if display_server == 'wayland':
        tools_to_test = ['wtype', 'ydotool', 'wl-copy']
    else:
        tools_to_test = ['xdotool', 'xclip']
    
    tools_to_test.extend(['pactl', 'notify-send'])
    
    success = True
    for tool in tools_to_test:
        try:
            subprocess.run([tool, '--help'], capture_output=True, timeout=5)
            print(f"✅ {tool} available")
        except (FileNotFoundError, subprocess.TimeoutExpired):
            print(f"❌ {tool} not found")
            success = False
    
    return success

def test_nemo():
    """Test NeMo import"""
    try:
        import nemo.collections.speechlm
        print("✅ NeMo Toolkit available")
        return True
    except ImportError as e:
        print(f"⚠️  NeMo import issue: {e}")
        return False

if __name__ == "__main__":
    print("🧪 Testing Speech-to-Text Installation")
    print("=" * 40)
    
    tests = [
        ("Python packages", test_imports),
        ("System tools", test_system_tools), 
        ("NeMo Toolkit", test_nemo)
    ]
    
    results = []
    for test_name, test_func in tests:
        print(f"\n🔍 Testing {test_name}...")
        results.append(test_func())
    
    print("\n" + "=" * 40)
    if all(results):
        print("🎉 All tests passed! Installation successful!")
        print("\nNext steps:")
        print("1. Copy speech_to_text.py and speech_hotkey.py to this directory")
        print("2. Run: ./run_speech_service.sh")
    else:
        print("⚠️  Some tests failed. Check the output above.")
        sys.exit(1)
EOF

# Run test
python test_installation.py

# Final setup
log_info "Final setup..."

# Create README
cat > README.md << 'EOF'
# Speech-to-Text with NVIDIA Canary

## Quick Start

1. **Start the service:**
   ```bash
   ./run_speech_service.sh
   ```

2. **Use hotkey:** Press `Super+P`, speak, release to transcribe

3. **Single recording:**
   ```bash
   source venv/bin/activate
   python speech_to_text.py -d 5  # Record for 5 seconds
   ```

## Files

- `speech_to_text.py` - Main speech recognition script
- `speech_hotkey.py` - System-wide hotkey service  
- `run_speech_service.sh` - Easy launcher
- `test_installation.py` - Test your setup

## Troubleshooting

- Test installation: `python test_installation.py`
- Check GPU: `nvidia-smi`
- Check audio: `pactl list sources short`

EOF

echo ""
log_success "Installation completed successfully!"
echo ""
echo "📁 Project directory: $PROJECT_DIR"
echo "🐍 Python version: $($PYTHON_CMD --version)"
echo "🎮 GPU support: $([[ $GPU_AVAILABLE == true ]] && echo "Yes ($GPU_NAME)" || echo "No (CPU only)")"
echo "🖥️  Display server: $DISPLAY_SERVER"
echo ""
echo "🚀 Ready to use! Start with:"
echo "   cd $PROJECT_DIR && ./run_speech_service.sh"
echo "📱 Hotkey: Super+P (Windows key + P)"
echo ""

if [[ "$DISPLAY_SERVER" == "wayland" ]] && ! groups "$USER" | grep -q input; then
    log_warning "For Wayland support, log out and back in for group changes to take effect"
fi

# Offer to start immediately
read -p "Start the speech-to-text service now? (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    log_info "Starting service..."
    ./run_speech_service.sh
fi
