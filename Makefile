SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX := $(shell xcrun --sdk iphoneos -f clang++)
SOURCES := src/Core.mm src/UI.mm src/Audit.mm src/Portable.cpp src/Identity.mm
FLAGS := -isysroot $(SDK) -arch arm64 -miphoneos-version-min=12.0 -fobjc-arc -std=c++17 -O2 -Wall -Wextra
.PHONY: all test
all: build/AZ.GPS.dylib
build/AZ.GPS.dylib: $(SOURCES) $(wildcard src/*.h)
	mkdir -p build
	$(CXX) $(FLAGS) -dynamiclib $(SOURCES) -framework Foundation -framework UIKit -framework CoreLocation -framework MapKit -framework CoreGraphics -framework QuartzCore -Wl,-install_name,@rpath/AZ.GPS.dylib -o $@
	codesign --force --sign - $@
test:
	mkdir -p build
	c++ -std=c++17 -Wall -Wextra Tests/AllTests.cpp src/Portable.cpp -o build/math-tests
	./build/math-tests
