# StikJIT Makefile 
# By neoarz

# Path to code signing tool
TARGET_CODESIGN = $(shell which ldid)

# Build configuration settings
PLATFORM = iphoneos
NAME = StikJIT
SCHEME ?= 'StikJIT'
RELEASE = Release-iphoneos
CONFIGURATION = Release

# SDK paths for compilation
MACOSX_SYSROOT = $(shell xcrun -sdk macosx --show-sdk-path)
TARGET_SYSROOT = $(shell xcrun -sdk $(PLATFORM) --show-sdk-path)

# Temporary build directories
APP_TMP         = $(TMPDIR)/$(NAME)
STAGE_DIR   = $(APP_TMP)/stage
APP_DIR 	   = $(APP_TMP)/Build/Products/$(RELEASE)/$(NAME).app

# Default target
all: package

# Main build target - compiles and packages the application
package:
	# Clean any previous build artifacts
	@rm -rf $(APP_TMP)
	
	# Build the app with xcodebuild
	# Uses parallel jobs to speed up compilation
	@set -o pipefail; \
		xcodebuild \
		-jobs $(shell sysctl -n hw.ncpu) \
		-project '$(NAME).xcodeproj' \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-arch arm64 -sdk $(PLATFORM) \
		-derivedDataPath $(APP_TMP) \
		CODE_SIGNING_ALLOWED=NO \
		DSTROOT=$(APP_TMP)/install \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		SWIFT_OPTIMIZATION_LEVEL="-Onone" \
		IPHONEOS_DEPLOYMENT_TARGET=17.4
		
	# Prepare the directory structure for packaging
	@rm -rf Payload
	@rm -rf $(STAGE_DIR)/
	@mkdir -p $(STAGE_DIR)/Payload
	@mv $(APP_DIR) $(STAGE_DIR)/Payload/$(NAME).app
	
	# Debug output - show paths for troubleshooting
	@echo $(APP_TMP)
	@echo $(STAGE_DIR)
	
	# Remove Apple's code signature so we can use our own
	@rm -rf $(STAGE_DIR)/Payload/$(NAME).app/_CodeSignature
	
	# Set up symbolic link for packaging
	@ln -sf $(STAGE_DIR)/Payload Payload
	
	# Prepare packages directory
	@rm -rf packages
	@mkdir -p packages
	
	# Create standard IPA package
	# Using max compression level (9) for smaller file size
	@zip -r9 packages/$(NAME).ipa Payload
	@rm -rf Payload

# Clean target - removes all temporary files and build artifacts
clean:
	@rm -rf $(STAGE_DIR)
	@rm -rf packages
	@rm -rf out.dmg
	@rm -rf $(APP_TMP)

# Phony target declaration
.PHONY: apple-include
