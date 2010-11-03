
ifdef LOC
TEST_LOC=--server $(LOC)
else
TEST_LOC=
endif

test:
	java -jar lib/JsTestDriver-1.2.2.jar --tests all --captureConsole $(TEST_LOC) --verbose

run_server:
	java -jar lib/JsTestDriver-1.2.2.jar --port 11981 $(SERVER_EXTRA)
