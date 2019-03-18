all: nfa_posix

nfa_posix.tab.c: nfa_posix.y
	bison -W $<

nfa_posix: nfa_posix.tab.c
	gcc -O2 -Wall $< -o $@

clean:
	rm -f nfa_posix nfa_posix.tab.c
