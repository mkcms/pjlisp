LDFLAGS += -lm -lfl

all: pjlisp

pjlisp.tab.c pjlisp.tab.h: pjlisp.y
	bison -d pjlisp.y

lex.yy.c: pjlisp.l pjlisp.tab.h
	flex pjlisp.l

pjlisp.tab.o: pjlisp.tab.c
lex.yy.o: lex.yy.c

pjlisp: lex.yy.o pjlisp.tab.o
	${CC} $^ ${LDFLAGS} -o pjlisp

check:
	./tests.sh

clean:
	rm -f pjlisp.tab.h pjlisp.tab.c pjlisp.tab.o lex.yy.c lex.yy.o pjlisp pjlisp.o
