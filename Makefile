build:
	swiftc transcribe.swift -o transcribe

clean:
	rm -f transcribe

.PHONY: build clean
