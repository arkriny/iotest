iotest
======

Iotest tests command output against the expected results
for the given input based on a testfile.

This is free software released into the public domain.

Usage
-----

	iotest COMMAND TESTFILE...


Testfile format
---------------

	input1
	---
	output1
	===
	input2
	---
	output2

The testfile consists of multiple testcases, each delimited by `===`. Each
testcase includes input lines and expected output lines, separated by `---`.
