/* -*- mode: c; -*- */

%{
#include "pjlisp.tab.h"

static int offset = 0;

#define YY_USER_ACTION { offset += yyleng; }

%}

FIXNUM     [-]?[0-9]+
ID         [!#$%&*+,-/0123456789:<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz|]+
WHITESPACE [[:space:]\n]+
STRING     \"(\\.|[^\"\\])*\"
COMMENT    ;[^\n;]*$

%%

\.            {return DOT;}
{FIXNUM}      {yylval = make_fixnum(atoi(yytext)); return FIXNUM;}
nil           {return NIL;}
{ID}          {yylval = intern(yytext); return ID;}
[\']          {return QUOTE;}
[(]           {return LPAREN;}
[)]           {return RPAREN;}
{STRING}      {yylval = make_string(yytext+1, yyleng-2); return STRING;}
{WHITESPACE}+ /* no-op */
{COMMENT}     /* no-op */
.             {
    fprintf(stderr, 
            "lexer: illegal character at byte position %d: %#x\n",
            offset - 1, (int)yytext[0] & 0xff); 
    abort();
}
