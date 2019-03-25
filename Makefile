all: nfa_posix nfa_posix_orig

nfa_posix.tab.c: nfa_posix.y
	bison -W $<

nfa_posix_orig.tab.c: nfa_posix_orig.y
	bison -W $<

nfa_posix: nfa_posix.tab.c
	g++ -g -O2 -Wall $< -o $@

nfa_posix_orig: nfa_posix_orig.tab.c
	gcc -g -O2 -Wall $< -o $@

clean:
	rm -f nfa_posix nfa_posix.tab.c
	rm -f nfa_posix_orig nfa_posix_orig.tab.c
