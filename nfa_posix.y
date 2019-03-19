/*
 * Regular expression implementation.
 * Supports traditional egrep syntax, plus non-greedy operators.
 * Tracks submatches a la POSIX.
 *
 * Seems to work (by running backward!) but very subtle.
 * Assumes repetitions are all individually parenthesized:
 * must say '(a?)b(c*)' not 'a?bc*'.
 *
 * Let m = length of regexp (number of states), and 
 * let p = number of capturing parentheses, and
 * let t = length of the text.  POSIX via running backward,
 * implemented here, requires O(m*p) storage during execution.
 * Can implement via running forward instead, but would
 * require O(m*p+m*m) storage and is not nearly so simple.
 *
 * yacc -v nfa-posix.y && gcc y.tab.c

These should be equivalent:

re='ab|cd|ef|a|bc|def|bcde|f'
a.out "(?:$re)(?:$re)($re)" abcdef
a.out "($re)*" abcdef

 (0,6)(3,6) => longest last guy (wrong)
 (0,6)(5,6) => shortest last guy (wrong)
 (0,6)(4,6) => posix last guy (right)

 * Copyright (c) 2007 Russ Cox.
 * Can be distributed under the MIT license, see bottom of file.
 */

%{
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <vector>

enum
{
    NSUB = 20,
    MPAREN = 9,
};

typedef struct Sub Sub;
struct Sub
{
    const char *sp;
    const char *ep;
};

enum
{
    Char = 1,
    Any = 2,
    Split = 3,
    LParen = 4,
    RParen = 5,
    Match = 6,
};
typedef struct State State;
typedef struct Thread Thread;
struct State
{
    int op;
    int data;
    State *out;
    State *out1;
    int id;
    int lastlist;
    Thread *lastthread;
};

struct Thread
{
    State *state;
    Sub match[NSUB];
};

typedef struct List List;
struct List
{
    Thread *t;
    int n;
};

int debug = 0;

State matchstate = { Match };
int nstate;
int listid;
List l1, l2;

/* Allocate and initialize State */
State* state(int op, int data, State *out, State *out1)
{
    State *s;
    nstate++;
    s = (State*)malloc(sizeof *s);
    s->lastlist = 0;
    s->op = op;
    s->data = data;
    s->out = out;
    s->out1 = out1;
    s->id = nstate;
    return s;
}

typedef struct Frag Frag;
typedef union Ptrlist Ptrlist;
struct Frag
{
    State *start;
    Ptrlist *out;
};

/* Initialize Frag struct. */
Frag frag(State *start, Ptrlist *out)
{
    Frag n = { start, out };
    return n;
}

/*
 * Since the out pointers in the list are always 
 * uninitialized, we use the pointers themselves
 * as storage for the Ptrlists.
 */
union Ptrlist
{
    Ptrlist *next;
    State *s;
};

/* Create singleton list containing just outp. */
Ptrlist* list1(State **outp)
{
    Ptrlist *l = (Ptrlist*)outp;
    l->next = NULL;
    return l;
}

/* Patch the list of states at out to point to start. */
void patch(Ptrlist *l, State *s)
{
    Ptrlist *next;
    for (; l; l = next) {
        next = l->next;
        l->s = s;
    }
}

/* Join the two lists l1 and l2, returning the combination. */
Ptrlist* append(Ptrlist *l1, Ptrlist *l2)
{
    Ptrlist *oldl1 = l1;
    while(l1->next)
    l1 = l1->next;
    l1->next = l2;
    return oldl1;
}

int nparen;
void yyerror(const char*);
int yylex(void);
State *start;

Frag paren(Frag f, int n)
{
    State *s1, *s2;
    if(n > MPAREN)
        return f;
    s1 = state(RParen, n, f.start, NULL);
    s2 = state(LParen, n, NULL, NULL);
    patch(f.out, s2);
    return frag(s1, list1(&s2->out));
}

%}

%union {
    Frag frag;
    int c;
    int nparen;
}

%token <c> CHAR
%token EOL

%type <frag>   alt concat repeat single line
%type <nparen> count

%%

line
: alt EOL {
    State *s;
    $1 = paren($1, 0);
    s = state(Match, 0, NULL, NULL);
    patch($1.out, s);
    start = $1.start;
    return 0;
};

alt
: concat
| alt '|' concat {
    State *s = state(Split, 0, $1.start, $3.start);
    $$ = frag(s, append($1.out, $3.out));
};

concat
: repeat
| concat repeat {
    patch($2.out, $1.start);
    $$ = frag($2.start, $1.out);
};

repeat
: single
| single '*' {
    State *s = state(Split, 0, $1.start, NULL);
    patch($1.out, s);
    $$ = frag(s, list1(&s->out1));
}
| single '+' {
    State *s = state(Split, 0, $1.start, NULL);
    patch($1.out, s);
    $$ = frag($1.start, list1(&s->out1));
}
| single '?' {
    State *s = state(Split, 0, $1.start, NULL);
    $$ = frag(s, append($1.out, list1(&s->out1)));
};

count
: { $$ = ++nparen; }

single
: '(' count alt ')' { $$ = paren($3, $2); }
| '(' '?' ':' alt ')' { $$ = $4; }
| CHAR {
    State *s = state(Char, $1, NULL, NULL);
    $$ = frag(s, list1(&s->out));
}
| '.' {
    State *s = state(Any, 0, NULL, NULL);
    $$ = frag(s, list1(&s->out));
};

%%

const char *input;
const char *text;
void dumplist(List*);

int yylex(void)
{
    int c;

    if(input == NULL || *input == 0)
    return EOL;
    c = *input++;
    if(strchr("|*?():.", c))
    return c;
    yylval.c = c;
    return CHAR;
}

void yyerror(const char *s)
{
    fprintf(stderr, "parse error: %s\n", s);
    exit(1);
}

void printmatch(Sub *m, int jump)
{
    for (int i = jump - 1; i < 2 * nparen + 2; i += jump) {
        if(m[i].sp && m[i].ep) {
            printf("(%ld,%ld)", m[i].sp - text, m[i].ep - text);
        }
        else if(m[i].sp) {
            printf("(%ld,?)", m[i].sp - text);
        }
        else {
            printf("(?,?)");
        }
    }
}

void dumplist(List *l)
{
    Thread *t;
    for (int i = 0; i < l->n; i++) {
        t = &l->t[i];
        if(t->state->op != Char && t->state->op != Any && t->state->op != Match) {
            continue;
        }
        printf("  ");
        printf("%d ", t->state->id);
        printmatch(t->match, 1);
        printf("\n");
    }
}

/*
 * Is match a better than match b?
 * If so, return 1; if not, 0.
 */
int _better(Sub *a, Sub *b)
{
    /* Leftmost longest */
    for (int i = 0; i < 2 * nparen + 2; i++) {
        if(a[i].sp != b[i].sp) {
            return b[i].sp == NULL
                || (a[i].sp != NULL && a[i].sp < b[i].sp);
        }
        if(a[i].ep != b[i].ep) {
            return a[i].ep > b[i].ep;
        }
    }
    return 0;
}

int better(Sub *a, Sub *b)
{
    int r = _better(a, b);
    if (debug > 1) {
        printf("better? ");
        printmatch(a, 1);
        printf(" vs ");
        printmatch(b, 1);
        printf(": %s\n", r ? "yes" : "no");
    }
    return r;
}

/*
 * Add s to l, following unlabeled arrows.
 * Next character to read is p.
 */
void addstate(List *l, State *s, Sub *m, const char *p)
{
    Sub save0, save1;

    if (s == NULL) return;

    if (s->lastlist == listid) {
        if (!better(m, s->lastthread->match)) {
            return;
        }
    }
    else {
        s->lastlist = listid;
        s->lastthread = &l->t[l->n++];
    }
    s->lastthread->state = s;
    memmove(s->lastthread->match, m, NSUB*sizeof m[0]);

    switch(s->op) {
    case Split:
        /* follow unlabeled arrows */
        addstate(l, s->out, m, p);
        addstate(l, s->out1, m, p);
        break;

    case LParen:
        save0 = m[2 * s->data];
        save1 = m[2 * s->data + 1];
        /* record left paren location and keep going */
        m[2 * s->data].sp = p;
        if (save1.sp == NULL) {
            m[2 * s->data + 1].sp = p;
        }
        /* replace empty match on the last iteration with the current match */
        else if (save1.sp == save1.ep) {
            m[2 * s->data + 1].sp = p;
            m[2 * s->data + 1].ep = m[2 * s->data].ep;
        }
        addstate(l, s->out, m, p);
        /* restore old information before returning. */
        m[2 * s->data] = save0;
        m[2 * s->data+1] = save1;
        break;

    case RParen:
        save0 = m[2 * s->data];
        save1 = m[2 * s->data + 1];
        /* record right paren location and keep going */
        m[2 * s->data].ep = p;
        m[2 * s->data].sp = NULL;
        if (save1.ep == NULL) {
            m[2 * s->data + 1].ep = p;
        }
        addstate(l, s->out, m, p);
        /* restore old information before returning. */
        m[2 * s->data] = save0;
        m[2 * s->data + 1] = save1;
        break;
    }
}

/*
 * Step the NFA from the states in clist
 * past the character c,
 * to create next NFA state set nlist.
 * Record best match so far in match.
 */
void step(List *clist, int c, const char *p, List *nlist, Sub *match)
{
    int i;
    Thread *t;
    static Sub m[NSUB];

    if (debug) {
        dumplist(clist);
        printf("%c (%d)\n", c, c);
    }

    listid++;
    nlist->n = 0;

    for(i=0; i<clist->n; i++){
        t = &clist->t[i];
        switch (t->state->op) {
        case Char:
            if(c == t->state->data)
            addstate(nlist, t->state->out, t->match, p);
            break;

        case Any:
            addstate(nlist, t->state->out, t->match, p);
            break;

        case Match:
            if(better(t->match, match))
            memmove(match, t->match, NSUB*sizeof match[0]);
            break;
        }
    }

    /* start a new thread */
    if(match == NULL) // || match[0].sp == NULL)
        addstate(nlist, start, m, p);
}

/* Compute initial thread list */
List* startlist(State *start, const char *p, List *l)
{
    List empty = {NULL, 0};
    step(&empty, 0, p, l, NULL);
    return l;
}

int match(State *start, const char *p, Sub *m)
{
    int c;
    List *clist, *nlist, *t;
    const char *q;

    q = p+strlen(p);
    clist = startlist(start, q, &l1);
    nlist = &l2;
    memset(m, 0, NSUB*sizeof m[0]);
    while (--q >= p) {
        c = *q & 0xFF;
        step(clist, c, q, nlist, m);
        t = clist; clist = nlist; nlist = t;
    }
    step(clist, 0, p, nlist, m);
    return m[0].sp != NULL;
}

void dump(State *s)
{
    if(s == NULL || s->lastlist == listid)
        return;

    s->lastlist = listid;
    printf("%d| ", s->id);

    switch(s->op){
    case Char:
        printf("'%c' -> %d\n", s->data, s->out->id);
        break;

    case Any:
        printf(". -> %d\n", s->out->id);
        break;

    case Split:
        printf("| -> %d, %d\n", s->out->id, s->out1->id);
        break;

    case LParen:
        printf("( %d -> %d\n", s->data, s->out->id);
        break;

    case RParen:
        printf(") %d -> %d\n", s->data, s->out->id);
        break;

    case Match:
        printf("match\n");
        break;

    default:
        printf("??? %d\n", s->op);
        break;
    }

    dump(s->out);
    dump(s->out1);
}

static int test(const char *pattern, const char *string
    , const std::vector<long> &pmatch)
{
    Sub m[NSUB];

    input = pattern;
    nparen = 0;
    yyparse();
    if(nparen >= MPAREN) {
        nparen = MPAREN;
    }

    if (debug) {
        ++listid;
        dump(start);
    }

    l1.t = (Thread*)malloc(nstate*sizeof l1.t[0]);
    l2.t = (Thread*)malloc(nstate*sizeof l2.t[0]);

    text = string; /* used by printmatch */

    int jump = 2;
    int ok = match(start, string, m);

    if (ok && debug) {
        printf("%s: ", string);
        printmatch(m, jump);
        printf("\n");
    }

    const size_t noffs = pmatch.size();
    assert(noffs == (size_t) 2 * nparen + 2);

    for (size_t i = 0; i < noffs; i += 2) {
        const long xs = m[i + 1].sp ? m[i + 1].sp - string : -1;
        const long xe = m[i + 1].ep ? m[i + 1].ep - string : -1;
        const long ys = pmatch[i];
        const long ye = pmatch[i + 1];
        if (xs != ys || xe != ye) {
            printf("error in %lu-th group, regexp %s, string %s\n", i / 2, pattern, string);
            printf("\texpect: ");
            for (size_t j = 0; j < noffs; j += 2) {
                printf("(%ld,%ld)", pmatch[j], pmatch[j + 1]);
            }
            printf("\n\tactual: ");
            printmatch(m, jump);
            printf("\n");
            break;
        }
    }

    return 0;
}

int main(int argc, char **argv)
{
    for (;;) {
        if(argc > 1 && strcmp(argv[1], "-d") == 0) {
            debug++;
            argv[1] = argv[0]; argc--; argv++;
        }
        else {
            break;
        }
    }

    test("a",          "a",        {0,1});
    test("(a)",        "a",        {0,1, 0,1});
    test("(a*)",       "aaa",      {0,3, 0,3});
    test("(a*)(b*)",   "aabb",     {0,4, 0,2, 2,4});
    test("(a*)(a*)",   "aa",       {0,2, 0,2, 2,2});
    test("(a|aa)*",    "aa",       {0,2, 0,2});
    test("(a)|(a)",    "a",        {0,1, 0,1, -1,-1});
    test("(a)*(a)*",   "a",        {0,1, 0,1, -1,-1});
    test("(a*)*",      "a",        {0,1, 0,1});
    test("(a*)*",      "aaaaaa",   {0,6, 0,6});
    test("((a|b)*)*",  "a",        {0,1, 0,1, 0,1});
    test("((a|b)*)*",  "aaaaaa",   {0,6, 0,6, 5,6});
    test("((a|b)*)*",  "ababab",   {0,6, 0,6, 5,6});
    test("((a|b)*)*",  "bababa",   {0,6, 0,6, 5,6});
    test("((a|b)*)*",  "b",        {0,1, 0,1, 0,1});
    test("((a|b)*)*",  "bbbbbb",   {0,6, 0,6, 5,6});
    test("((a|b)*)*",  "aaaab",    {0,5, 0,5, 4,5});
    test("(a*)*(x)",   "x",        {0,1, 0,0, 0,1});
    test("(a*)*(x)",   "ax",       {0,2, 0,1, 1,2});
    test("(a?)((ab)?)",                    "ab",      {0,2, 0,0, 0,2, 0,2});
    test("(a?)((ab)?)(b?)",                "ab",      {0,2, 0,1, 1,1, -1,-1, 1,2});
    test("((a?)((ab)?))(b?)",              "ab",      {0,2, 0,2, 0,0, 0,2, 0,2, 2,2});
    test("(a?)(((ab)?)(b?))",              "ab",      {0,2, 0,1, 1,2, 1,1, -1,-1, 1,2});
    test("(.?)",                           "x",       {0,1, 0,1});
    test("(.?)(.?)",                       "x",       {0,1, 0,1, 1,1});
    test("(.?)*",                          "x",       {0,1, 0,1});
    test("(.?.?)",                         "xx",      {0,2, 0,2});
    test("(.?.?)(.?.?)",                   "xxx",     {0,3, 0,2, 2,3});
    test("(.?.?)(.?.?)(.?.?)",             "xxx",     {0,3, 0,2, 2,3, 3,3});
    test("(.?.?)*",                        "xx",      {0,2, 0,2});
    test("(.?.?)*",                        "xxx",     {0,3, 2,3});
    test("(.?.?)*",                        "xxxx",    {0,4, 2,4});
    test("(a?)((ab)?)b?",                  "ab",      {0,2, 0,1, 1,1, -1,-1});
    test("(a|ab)(ba|a)",                   "aba",     {0,3, 0,2, 2,3});
    test("(a|ab|ba)",                      "ab",      {0,2, 0,2});
    test("(a|ab|ba)(a|ab|ba)",             "aba",     {0,3, 0,2, 2,3});
    test("(a|ab|ba)*",                     "aba",     {0,3, 2,3});
    test("(aba|a*b)",                      "aba",     {0,3, 0,3});
    test("(aba|a*b)(aba|a*b)",             "ababa",   {0,5, 0,2, 2,5});
    test("(aba|a*b)*",                     "ababa",   {0,5, 2,5});
    test("(aba|ab|a)",                     "aba",     {0,3, 0,3});
    test("(aba|ab|a)(aba|ab|a)",           "ababa",   {0,5, 0,2, 2,5});
    test("(aba|ab|a)(aba|ab|a)(aba|ab|a)", "ababa",   {0,5, 0,2, 2,4, 4,5});
    test("(aba|ab|a)*",                    "ababa",   {0,5, 2,5});
    test("(a(b)?)",                        "ab",      {0,2, 0,2, 1,2});
    test("(a(b)?)(a(b)?)",                 "aba",     {0,3, 0,2, 1,2, 2,3, -1,-1});
    test("(.*)(.*)",                       "xx",      {0,2, 0,2, 2,2});
    test("(a.*z|b.*y)",                    "azbaz",   {0,5, 0,5});
    test("(a.*z|b.*y)(a.*z|b.*y)",         "azbazby", {0,7, 0,5, 5,7});
    test("(a.*z|b.*y)*",                   "azbazby", {0,7, 5,7});
    test("(.|..)(.*)",                     "ab",      {0,2, 0,2, 2,2});
    test("((..)*(...)*)",                  "xxx",     {0,3, 0,3, -1,-1, 0,3});
    test("((..)*(...)*)((..)*(...)*)",     "xxx",     {0,3, 0,3, -1,-1, 0,3, 3,3, -1,-1, -1,-1});
    test("((..)*(...)*)*",                 "xxx",     {0,3, 0,3, -1,-1, 0,3});
    test("(a|aa)*",                            "aaa",         {0,3, 2,3});
    test("(a|aa)*",                            "aaaa",        {0,4, 2,4});
    test("(aa|a)*",                            "aaa",         {0,3, 2,3});
    test("(aa|a)*",                            "aaaa",        {0,4, 2,4});
    test("(a)|a",                              "a",           {0,1, 0,1});
    test("(b)a|b(a)",                          "ba",          {0,2, 0,1, -1,-1});
    test("b(a)|(b)a",                          "ba",          {0,2, 1,2, -1,-1});
    test("(a|aa)*|a*",                         "aa",          {0,2, 0,2});
    test("(aa*|aaa*)*",                        "aaaaaa",      {0,6, 0,6});
    test("(aa*|aaa*)(aa*|aaa*)",               "aaaaaa",      {0,6, 0,5, 5,6});
    test("((aa)*|(aaa)*)((aa)*|(aaa)*)",       "aaaaaa",      {0,6, 0,6, 4,6, -1,-1, 6,6, -1,-1, -1,-1});
    test("(aa)*|(aaa)*",                       "aaaaaa",      {0,6, 4,6, -1,-1});
    test("(X|Xa|Xab|Xaba|abab|baba|bY|Y)*",    "XY",          {0,2, 1,2});
    test("(X|Xa|Xab|Xaba|abab|baba|bY|Y)*",    "XabY",        {0,4, 3,4});
    test("(X|Xa|Xab|Xaba|abab|baba|bY|Y)*",    "XababY",      {0,6, 4,6});
    test("(X|Xa|Xab|Xaba|abab|baba|bY|Y)*",    "XabababY",    {0,8, 7,8});
    test("(X|Xa|Xab|Xaba|abab|baba|bY|Y)*",    "XababababY",  {0,10, 8,10});

    // forcedassoc
    test("(a|ab)(c|bcd)",       "abcd", {0,4, 0,1, 1,4});
    test("(a|ab)(bcd|c)",       "abcd", {0,4, 0,1, 1,4});
    test("(ab|a)(c|bcd)",       "abcd", {0,4, 0,1, 1,4});
    test("(ab|a)(bcd|c)",       "abcd", {0,4, 0,1, 1,4});
    test("((a|ab)(c|bcd))(d*)", "abcd", {0,4, 0,4, 0,1, 1,4, 4,4});
    test("((a|ab)(bcd|c))(d*)", "abcd", {0,4, 0,4, 0,1, 1,4, 4,4});
    test("((ab|a)(c|bcd))(d*)", "abcd", {0,4, 0,4, 0,1, 1,4, 4,4});
    test("((ab|a)(bcd|c))(d*)", "abcd", {0,4, 0,4, 0,1, 1,4, 4,4});
    test("(a|ab)((c|bcd)(d*))", "abcd", {0,4, 0,2, 2,4, 2,3, 3,4});
    test("(a|ab)((bcd|c)(d*))", "abcd", {0,4, 0,2, 2,4, 2,3, 3,4});
    test("(ab|a)((c|bcd)(d*))", "abcd", {0,4, 0,2, 2,4, 2,3, 3,4});
    test("(ab|a)((bcd|c)(d*))", "abcd", {0,4, 0,2, 2,4, 2,3, 3,4});
    test("(a*)(b|abc)",         "abc",  {0,3, 0,0, 0,3});
    test("(a*)(abc|b)",         "abc",  {0,3, 0,0, 0,3});
    test("((a*)(b|abc))(c*)",   "abc",  {0,3, 0,3, 0,0, 0,3, 3,3});
    test("((a*)(abc|b))(c*)",   "abc",  {0,3, 0,3, 0,0, 0,3, 3,3});
    test("(a*)((b|abc)(c*))",   "abc",  {0,3, 0,1, 1,3, 1,2, 2,3});
    test("(a*)((abc|b)(c*))",   "abc",  {0,3, 0,1, 1,3, 1,2, 2,3});
    test("(a*)(b|abc)",         "abc",  {0,3, 0,0, 0,3});
    test("(a*)(abc|b)",         "abc",  {0,3, 0,0, 0,3});
    test("((a*)(b|abc))(c*)",   "abc",  {0,3, 0,3, 0,0, 0,3, 3,3});
    test("((a*)(abc|b))(c*)",   "abc",  {0,3, 0,3, 0,0, 0,3, 3,3});
    test("(a*)((b|abc)(c*))",   "abc",  {0,3, 0,1, 1,3, 1,2, 2,3});
    test("(a*)((abc|b)(c*))",   "abc",  {0,3, 0,1, 1,3, 1,2, 2,3});
    test("(a|ab)",              "ab",   {0,2, 0,2});
    test("(ab|a)",              "ab",   {0,2, 0,2});
    test("(a|ab)(b*)",          "ab",   {0,2, 0,2, 2,2});
    test("(ab|a)(b*)",          "ab",   {0,2, 0,2, 2,2});

    return 0;
}

/*
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated
 * documentation files (the "Software"), to deal in the
 * Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute,
 * sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall
 * be included in all copies or substantial portions of the
 * Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
 * KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
 * WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 * PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS
 * OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
