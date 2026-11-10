.PHONY: prepare build test
prepare:
	python3 tools/prepare-kernel.py
build:
	tools/build-source.sh
test:
	python3 tools/cerro-dualboot/host/test_switch_system.py
	cd patches/cellular-dsds-c1 && python3 test-sms-pdu.py
