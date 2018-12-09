/* pjlisp  -*- mode: c; -*- */
/* Global declarations visible only in final .c file.  */
%{
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int yylex(void);
void yyerror(char const *);

struct lisp_object;
typedef struct lisp_object *object;

/* The last expression parsed by yyparse().  */
object parsed;

int eof = 0;

/* Signal a lisp error.  */
void signal(object error_symbol, object data);

/* Evaluate a single expression.  */
object eval(object obj);

typedef enum {
    T_CONS,
    T_STRING,
    T_SYMBOL,
    T_FIXNUM,
    T_SPECIAL_FORM,
    T_BUILTIN_FUNCTION_1,
    T_BUILTIN_FUNCTION_2,
    T_LAMBDA,
} object_type_t;

/* Signature for functions which behave like "macros".  Arguments to
 * these functions are not evaluated.  The argument is a cons.  */
typedef object (*special_form_t)(object args);

/* Signature for a builtin function accepting one argument.  The
 * argument is already evaluated.  */
typedef object (*function1_t)(object arg);

/* Signature for a builtin function accepting two arguments.  Both
 * arguments are already evaluated.  */
typedef object (*function2_t)(object arg1, object arg2);

struct lambda {
    object argumentlist;
    object body;
};

struct lisp_object {
    union {
        struct {
            object car;
            object cdr;
        };
        char *string;
        const char *symbol;
        int fixnum;
        special_form_t form;
        function1_t function1;
        function2_t function2;
        struct lambda *lambda;
    };
    object_type_t type;
};

object t;                       /* `true` value. */

#define NILP(obj) ((obj) == NULL)
#define CONSP(obj) (!NILP(obj) && (obj)->type == T_CONS)
#define FIXNUMP(obj) (!NILP(obj) && (obj)->type == T_FIXNUM)
#define STRINGP(obj) (!NILP(obj) && (obj)->type == T_STRING)
#define SYMBOLP(obj) (!NILP(obj) && (obj)->type == T_SYMBOL)

#define XCAR(obj) (NILP(obj) ? NULL : (obj)->car)
#define XCDR(obj) (NILP(obj) ? NULL : (obj)->cdr)
#define XINT(obj) ((obj)->fixnum)
#define XSYMBOL(obj) ((obj)->symbol)
#define XSTRING(obj) ((obj)->string)

#define error(fmt, ...)                                                        \
    do {                                                                       \
        fprintf(stderr, fmt, ##__VA_ARGS__);                                   \
        abort();                                                               \
    } while (0)\

%}


/* Declarations visible everywhere.  They need to be visible in
 * pjlisp.l.  */
%code requires {

typedef struct lisp_object *object;

object make_string(const char *string, size_t length);
object make_fixnum(int value);
object intern(const char *name);
object make_cons(object car, object cdr);
}


/* Parser */
%define api.value.type {object}

%token FIXNUM
%token ID
%token LPAREN
%token RPAREN
%token QUOTE
%token STRING
%token DOT
%token NIL

%%

pjlisp:
%empty { eof = 1; }
| exp { parsed = $1; YYACCEPT; }


exp:
atom
| cons
| QUOTE exp { $$ = make_cons(intern("quote"), make_cons($2, NULL)); }
| error
;

atom:
FIXNUM
| STRING
| ID
| NIL { $$ = NULL; }
;

cons:
LPAREN consbody RPAREN { $$ = $2; }
;

consbody: explist | dotted

explist:
%empty { $$ = NULL;}
| nonempty_explist
;

nonempty_explist: exp explist { $$ = make_cons($1, $2); }

dotted: nonempty_explist DOT exp {
    object head = $1;
    while (CONSP(head) && !NILP(XCDR(head))) {
        head = XCDR(head);
    }
    head->cdr = $3;
    $$ = $1;
}

%%


/* Helpers */

/* Get the length of OBJ, cons or a string.  Return -1 if it can't
 * have a length, -2 if it's not a proper list. */
ptrdiff_t length(object obj) {
    if (NILP(obj)) {
        return 0;
    }
    if (STRINGP(obj)) {
        return strlen(XSTRING(obj));
    }
    if (!CONSP(obj)) {
        return -1;
    }
    ptrdiff_t ret = 0;
    while (CONSP(obj)) {
        ret++;
        obj = XCDR(obj);
    }
    if (!NILP(obj)) {
        return -2;
    }
    return ret;
}

/* Concatenate two strings. */
object concat(object obj1, object obj2) {
    const char *str1 = XSTRING(obj1);
    const char *str2 = XSTRING(obj2);
    size_t len1 = strlen(str1);
    size_t len2 = strlen(str2);
    char *s = malloc((1 + len1 + len2) * sizeof(char));
    *s = 0;
    strcat(s, str1);
    strcat(s, str2);
    object obj = make_string(s, len1 + len2);
    free(s);
    return obj;
}


/* Hash */

/* Modified version of djb2 hash function from
 * http://www.cse.yorku.ca/~oz/hash.html */
size_t fasthash(object obj) {
    if (NILP(obj)) {
        return 0;
    }
    const char *str = (const char *)(obj);
    size_t hash = 5381;
    int i = 0;
    int c;
    size_t size = sizeof(struct lisp_object);

    if (FIXNUMP(obj)) {
        str = (const char *)&obj->fixnum;
        size = sizeof(obj->fixnum);
    }
    while (i++ < size) {
        c = *str++;
        hash = ((hash << 5) + hash) + c; /* hash * 33 + c */
    }

    return hash;
}

size_t hash(object obj) {
    if (NILP(obj)) {
        return 0;
    }

    if (obj->type != T_SYMBOL && obj->type != T_STRING) {
        return fasthash(obj);
    }

    const char *str = obj->type == T_SYMBOL ? obj->symbol : obj->string;
    size_t hash = 5381;
    int c;

    while ((c = *str++) != '\0') {
        hash = ((hash << 5) + hash) + c; /* hash * 33 + c */
    }

    return hash;
}

typedef struct hash_table {
    size_t nbuckets;
    size_t nobjects;
    object *buckets;
    size_t (*hashfn)(object obj);
    object (*equalfn)(object a, object b);
} hash_table;

#define HT_LOAD_FACTOR (0.75)

void hash_put(hash_table *table, object key, object value);

void hash_resize(hash_table *table) {
    hash_table new;
    memset(&new, 0, sizeof(hash_table));
    new.hashfn = table->hashfn;
    new.equalfn = table->equalfn;

    size_t newsize = table->nbuckets + (size_t)(0.25 * table->nbuckets);
    if (newsize == table->nbuckets) {
        newsize++;
    }

    new.buckets = calloc(newsize, sizeof(object));
    new.nbuckets = newsize;
    for (int i = 0; i < table->nbuckets; i++) {
        object head = table->buckets[i];
        while (!NILP(head)) {
            hash_put(&new, XCAR(XCAR(head)), XCDR(XCAR(head)));
            head = XCDR(head);
        }
    }

    free(table->buckets);
    table->nobjects = new.nobjects;
    table->nbuckets = new.nbuckets;
    table->buckets = new.buckets;
}

void hash_put(hash_table *table, object key, object value) {
    if (table->nbuckets == 0 ||
        (float)(table->nobjects) / table->nbuckets >= HT_LOAD_FACTOR) {
        hash_resize(table);
    }
    size_t h = table->hashfn(key);
    size_t index = h % table->nbuckets;

    object bucket = table->buckets[index];
    object head = bucket;
    while (!NILP(head)) {
        object elt = XCAR(head);

        if (!NILP(table->equalfn(XCAR(elt), key))) {
            elt->cdr = value;
            return;
        }

        head = XCDR(head);
    }
    bucket = make_cons(make_cons(key, value), bucket);
    table->buckets[index] = bucket;
    table->nobjects++;
}

object *hash_get(hash_table *table, object key) {
    if (table->nbuckets == 0) {
        return NULL;
    }
    size_t h = table->hashfn(key);
    size_t index = h % table->nbuckets;

    object bucket = table->buckets[index];
    object head = bucket;
    while (!NILP(head)) {
        object elt = XCAR(head);

        if (!NILP(table->equalfn(XCAR(elt), key))) {
            return &elt->cdr;
        }

        head = XCDR(head);
    }

    return NULL;
}


/* Memory allocation */

object *objects = NULL;
size_t nobjects = 0;
size_t capacity = 0;

object alloc(object_type_t type) {
    if (capacity - nobjects == 0) {
        object *old = objects;
        capacity = capacity == 0 ? 1 : 2 * capacity;
        objects = malloc(capacity * sizeof(object));
        for (int i = 0; i < nobjects; i++) {
            objects[i] = old[i];
        }
        free(old);
    }

    object obj = malloc(sizeof(struct lisp_object));
    obj->type = type;
    objects[nobjects++] = obj;
    return obj;
}

object make_cons(object car, object cdr) {
    object obj = alloc(T_CONS);
    obj->car = car;
    obj->cdr = cdr;
    return obj;
}

object make_fixnum(int value) {
    object obj = alloc(T_FIXNUM);
    obj->fixnum = value;
    return obj;
}

object make_string(const char *string, size_t length) {
    object obj = alloc(T_STRING);

    char *s = malloc((1 + length) * sizeof(char));
    strncpy(s, string, length);
    s[length] = '\0';

    obj->string = s;
    return obj;
}

object make_special_form(special_form_t func) {
    object obj = alloc(T_SPECIAL_FORM);
    obj->form = func;
    return obj;
}

object make_function1(function1_t func) {
    object obj = alloc(T_BUILTIN_FUNCTION_1);
    obj->function1 = func;
    return obj;
}

object make_function2(function2_t func) {
    object obj = alloc(T_BUILTIN_FUNCTION_2);
    obj->function2 = func;
    return obj;
}


/* Lookup */

object local_variables = NULL;

hash_table interned_symbols;
hash_table global_variables;

object intern(const char *name) {
    struct lisp_object uninterned_obj;
    uninterned_obj.type = T_STRING;
    uninterned_obj.string = (char *)name;

    object sym = &uninterned_obj;

    object *interned = hash_get(&interned_symbols, sym);
    if (interned != NULL) {
        return *interned;
    }

    sym = make_string(name, strlen(name));
    object o = alloc(T_SYMBOL);
    o->symbol = strdup(name);
    hash_put(&interned_symbols, sym, o);

    return o;
}

object *lookup(object sym, int create) {
    if (!SYMBOLP(sym)) {
        error("lookup: trying to lookup non-symbol");
    }

    object vars = local_variables;
    while (CONSP(vars)) {
        object alist = XCAR(vars);
        vars = XCDR(vars);

        while (CONSP(alist)) {
            if (!strcmp(XSYMBOL(XCAR(XCAR(alist))), XSYMBOL(sym))) {
                return &alist->car->cdr;
            }

            alist = XCDR(alist);
        }
    }

    object *res = hash_get(&global_variables, sym);
    if (res != NULL || create == 0) {
        return res;
    }

    hash_put(&global_variables, sym, NULL);
    return hash_get(&global_variables, sym);
}


/* Evaluation */

object current_signal = NULL;

void signal(object error_symbol, object data) {
    current_signal = make_cons(error_symbol, data);
}

object eval_lambda(struct lambda *lambda, object args) {
    object argument_alist = NULL;
    object lambda_symbol = lambda->argumentlist;
    while (CONSP(args)) {
        if (NILP(lambda_symbol)) {
            signal(intern("wrong-number-of-arguments"), NULL);
            return NULL;
        }
        object arg = eval(XCAR(args));
        if (!NILP(current_signal)) {
            return NULL;
        }
        args = XCDR(args);
        argument_alist =
            make_cons(make_cons(XCAR(lambda_symbol), arg), argument_alist);
        lambda_symbol = XCDR(lambda_symbol);
    }
    if (CONSP(lambda_symbol)) {
        signal(intern("wrong-number-of-arguments"), NULL);
        return NULL;
    }

    local_variables = make_cons(argument_alist, local_variables);

    object res = NULL;
    object body = lambda->body;
    while (CONSP(body)) {
        res = eval(XCAR(body));
        if (!NILP(current_signal)) {
            break;
        }
        body = XCDR(body);
    }

    local_variables = XCDR(local_variables);

    return res;
}

object eval(object obj) {
    if (NILP(obj)) {
        return obj;
    }
    if (!NILP(current_signal)) {
        error("eval: current_signal is set");
    }

    switch (obj->type) {
    case T_CONS: {
        object function = eval(XCAR(obj));
        if (!NILP(current_signal)) {
            return NULL;
        }
        object args = XCDR(obj);
        ptrdiff_t nargs = length(args);
        if (nargs < 0) {
            signal(intern("wrong-type-argument"), intern("listp"));
            return NULL;
        }
        if (function->type == T_SPECIAL_FORM) {
            return function->form(args);
        }
        if (function->type == T_BUILTIN_FUNCTION_1) {
            if (nargs != 1) {
                signal(intern("wrong-number-of-arguments"), make_fixnum(1));
                return NULL;
            }

            object arg = eval(XCAR(args));
            if (!NILP(current_signal)) {
                return NULL;
            }
            return function->function1(arg);
        }
        if (function->type == T_BUILTIN_FUNCTION_2) {
            if (nargs != 2) {
                signal(intern("wrong-number-of-arguments"), make_fixnum(2));
                return NULL;
            }

            object arg1 = eval(XCAR(args));
            if (!NILP(current_signal)) {
                return NULL;
            }
            object arg2 = eval(XCAR(XCDR(args)));
            if (!NILP(current_signal)) {
                return NULL;
            }
            return function->function2(arg1, arg2);
        }
        if (function->type == T_LAMBDA) {
            struct lambda *lambda = function->lambda;
            return eval_lambda(lambda, args);
        }
        signal(intern("invalid-function"), function);
        return NULL;
    }
    case T_SYMBOL: {
        object *value = lookup(obj, 0);
        if (value == NULL) {
            signal(intern("void-variable"), obj);
            return NULL;
        }
        return *value;
    }
    case T_FIXNUM:
    case T_STRING:
    case T_SPECIAL_FORM:
        return obj;
    }

    error("eval");
}


/* Built-in functions. */

object Fquote(object args) {
    if (NILP(args) || !NILP(XCDR(args))) {
        signal(intern("wrong-number-of-arguments"), make_fixnum(1));
        return NULL;
    }
    return XCAR(args);
}

object Fprogn(object args) {
    object res = NULL;

    while (CONSP(args)) {
        res = eval(XCAR(args));
        if (!NILP(current_signal)) {
            return NULL;
        }
        args = XCDR(args);
    }

    return res;
}

object Fset(object symbol, object value) {
    if (!SYMBOLP(symbol)) {
        signal(intern("wrong-type-argument"),
               make_cons(intern("symbolp"), symbol));
        return NULL;
    }

    object *ptr = lookup(symbol, 1);
    *ptr = value;

    return value;
}

object Fnot(object arg) {
    if (NILP(arg)) {
        return intern("t");
    }
    return NULL;
}

object Flength(object sequence) {
    ptrdiff_t len = length(sequence);
    if (len < 0) {
        signal(intern("wrong-type-argument"),
               make_cons(intern("listp"), sequence));
        return NULL;
    }
    return make_fixnum(len);
}

object Fcons(object car, object cdr) { return make_cons(car, cdr); }

object Fcar(object arg) {
    if (!(NILP(arg) || CONSP(arg))) {
        signal(intern("wrong-type-argument"), intern("consp"));
        return NULL;
    }

    return XCAR(arg);
}

object Fcdr(object arg) {
    if (!(NILP(arg) || CONSP(arg))) {
        signal(intern("wrong-type-argument"), intern("consp"));
        return NULL;
    }

    return XCDR(arg);
}

object Fstringify(object obj) {
    if (NILP(obj)) {
        return make_string("nil", 3);
    }
    switch (obj->type) {
    case T_CONS: {
        object res = make_string("(", 1);

        while (!NILP(obj)) {
            object elem = obj;
            object next = NULL;
            if (CONSP(obj)) {
                elem = XCAR(obj);
                next = XCDR(obj);
            } else {
                res = concat(res, make_string(". ", 3));
            }

            if (STRINGP(elem)) {
                const char *str = XSTRING(elem);
                size_t len = strlen(str);
                elem = make_string("\"", len + 2);
                char *new = XSTRING(elem);
                strncpy(new + 1, str, len);
                new[len + 1] = '\"';
                new[len + 2] = '\0';
                res = concat(res, elem);
            } else {
                res = concat(res, Fstringify(elem));
            }

            if (!NILP(next)) {
                res = concat(res, make_string(" ", 1));
            }
            obj = next;
        }
        res = concat(res, make_string(")", 1));
        return res;
    }
    case T_FIXNUM: {
        char s[32];
        sprintf(s, "%d", XINT(obj));
        return make_string(s, strlen(s));
    }
    case T_STRING:
        return obj;
    case T_SYMBOL:
        return make_string(XSYMBOL(obj), strlen(XSYMBOL(obj)));
    case T_SPECIAL_FORM:
    case T_BUILTIN_FUNCTION_2:
    case T_BUILTIN_FUNCTION_1: {
        char s[128];
        if (obj->type == T_SPECIAL_FORM) {
            sprintf(s, "special form at %p", obj->form);
        } else if (obj->type == T_BUILTIN_FUNCTION_1) {
            sprintf(s, "built-in function at %p", obj->function1);
        } else if (obj->type == T_BUILTIN_FUNCTION_2) {
            sprintf(s, "built-in function at %p", obj->function2);
        }
        return make_string(s, strlen(s));
    }
    case T_LAMBDA:
        return make_string("lambda", 6);
    default:
        error("stringify: unknown type %d", obj->type);
    }
}

object Flambda(object args) {
    if (!CONSP(XCAR(args)) && !NILP(XCAR(args))) {
        signal(intern("wrong-type-argument"), intern("consp"));
        return NULL;
    }

    object body = XCDR(args);
    object arg = XCAR(args);
    object arglist = arg;
    while (CONSP(arg)) {
        if (!SYMBOLP(XCAR(arg))) {
            signal(intern("wrong-type-argument"), intern("symbolp"));
            return NULL;
        }
        arg = XCDR(arg);
    }

    struct lambda *lambda = malloc(sizeof(struct lambda));
    lambda->argumentlist = arglist;
    lambda->body = body;

    object ret = alloc(T_LAMBDA);
    ret->lambda = lambda;

    return ret;
}

object Flet(object args) {
    if (!CONSP(XCAR(args)) && !NILP(XCAR(args))) {
        signal(intern("wrong-type-argument"), intern("consp"));
        return NULL;
    }

    object variable_alist = NULL;

    object arglist = XCAR(args);
    object body = XCDR(args);

    while (CONSP(arglist)) {
        object elt = XCAR(arglist);
        if (!CONSP(elt)) {
            signal(intern("lisp-error"), make_cons(intern("consp"), elt));
            return NULL;
        }
        if (!SYMBOLP(XCAR(elt))) {
            signal(intern("lisp-error"),
                   make_cons(intern("symbolp"), XCAR(elt)));
            return NULL;
        }
        if (!CONSP(XCDR(elt))) {
            signal(intern("lisp-error"), NULL);
            return NULL;
        }
        if (!NILP(XCDR(XCDR(elt)))) {
            signal(intern("lisp-error"), NULL);
            return NULL;
        }

        object symbol = XCAR(elt);
        object value = eval(XCAR(XCDR(elt)));
        if (!NILP(current_signal)) {
            return NULL;
        }

        variable_alist = make_cons(make_cons(symbol, value), variable_alist);
        arglist = XCDR(arglist);
    }

    local_variables = make_cons(variable_alist, local_variables);
    object result = Fprogn(body);
    local_variables = XCDR(local_variables);
    return result;
}

object Fplus(object args) {
    int ret = 0;

    while (CONSP(args)) {
        object val = eval(XCAR(args));
        if (!NILP(current_signal)) {
            return NULL;
        }
        if (!FIXNUMP(val)) {
            signal(intern("wrong-type-argument"), intern("numberp"));
            return NULL;
        }
        ret += XINT(val);
        args = XCDR(args);
    }

    return make_fixnum(ret);
}

object Fminus(object args) {
    int ret = 0;

    if (CONSP(args)) {
        ret = XINT(eval(XCAR(args)));
        if (!NILP(current_signal)) {
            return NULL;
        }
        args = XCDR(args);
        if (!CONSP(args)) {
            ret = -ret;
        }
    }

    while (CONSP(args)) {
        object val = eval(XCAR(args));
        if (!NILP(current_signal)) {
            return NULL;
        }
        if (!FIXNUMP(val)) {
            signal(intern("wrong-type-argument"), intern("numberp"));
            return NULL;
        }
        ret -= XINT(val);
        args = XCDR(args);
    }

    return make_fixnum(ret);
}

object Fmultiply(object args) {
    int ret = 1;

    while (CONSP(args)) {
        object val = eval(XCAR(args));
        if (!NILP(current_signal)) {
            return NULL;
        }
        if (!FIXNUMP(val)) {
            signal(intern("wrong-type-argument"), intern("numberp"));
            return NULL;
        }
        ret *= XINT(val);
        args = XCDR(args);
    }

    return make_fixnum(ret);
}

object Fless(object number1, object number2) {
    if (!FIXNUMP(number1)) {
        signal(intern("wrong-type-argument"), number1);
        return NULL;
    }
    if (!FIXNUMP(number2)) {
        signal(intern("wrong-type-argument"), number2);
        return NULL;
    }
    if (XINT(number1) < XINT(number2)) {
        return intern("t");
    }
    return NULL;
}

object Feq(object obj1, object obj2) {
    int res;
    if (FIXNUMP(obj1) && FIXNUMP(obj2)) {
        res = XINT(obj1) == XINT(obj2);
    } else {
        res = obj1 == obj2;
    }
    return res == 0 ? NULL : t;
}

object Fequal(object obj1, object obj2) {
    if (!NILP(Feq(obj1, obj2))) {
        return t;
    }
    int res = 0;
    if (STRINGP(obj1) && STRINGP(obj2)) {
        res = strcmp(XSTRING(obj1), XSTRING(obj2)) == 0;
    } else if (CONSP(obj1) && CONSP(obj2)) {
        res = !NILP(Fequal(XCAR(obj1), XCAR(obj2))) &&
              !NILP(Fequal(XCDR(obj1), XCDR(obj2)));
    }
    return res == 0 ? NULL : t;
}

object Fif(object args) {
    object cond = eval(XCAR(args));

    if (!NILP(current_signal)) {
        return NULL;
    }

    if (!NILP(cond)) {
        return eval(XCAR(XCDR(args)));
    }

    return Fprogn(XCDR(XCDR(args)));
}

object Fwhile(object args) {
    object res = NULL;

    while (1) {
        object cond = eval(XCAR(args));
        if (!NILP(current_signal) || NILP(cond)) {
            break;
        }

        res = Fprogn(XCDR(args));
        if (!NILP(current_signal)) {
            return NULL;
        }
    }

    return res;
}

object Fprint(object obj) {
    if (STRINGP(obj)) {
        printf("\"%s\"\n", XSTRING(obj));
    } else if (SYMBOLP(obj)) {
        puts(XSYMBOL(obj));
    } else if (FIXNUMP(obj)) {
        printf("%d\n", XINT(obj));
    } else {
        obj = Fstringify(obj);
        puts(XSTRING(obj));
    }
    return obj;
}


/* main */

void setup_builtins() {
    t = make_fixnum(1);

    Fset(intern("nil"), NULL);

    Fset(intern("t"), intern("t"));
    t = intern("t");

    Fset(intern("quote"), make_special_form(Fquote));

    Fset(intern("set"), make_function2(Fset));

    Fset(intern("lambda"), make_special_form(Flambda));

    Fset(intern("let"), make_special_form(Flet));

    Fset(intern("not"), make_function1(Fnot));

    Fset(intern("stringify"), make_function1(Fstringify));

    Fset(intern("print"), make_function1(Fprint));

    Fset(intern("+"), make_special_form(Fplus));

    Fset(intern("-"), make_special_form(Fminus));

    Fset(intern("*"), make_special_form(Fmultiply));

    Fset(intern("length"), make_function1(Flength));

    Fset(intern("cons"), make_function2(Fcons));

    Fset(intern("car"), make_function1(Fcar));

    Fset(intern("cdr"), make_function1(Fcdr));

    Fset(intern("<"), make_function2(Fless));

    Fset(intern("progn"), make_special_form(Fprogn));

    Fset(intern("if"), make_special_form(Fif));

    Fset(intern("eq"), make_function2(Feq));

    Fset(intern("equal"), make_function2(Fequal));

    Fset(intern("while"), make_special_form(Fwhile));
}

int main(int argc, char **argv) {
    bool repl = argc > 1 && !strcmp(argv[1], "--repl");

    memset(&interned_symbols, 0, sizeof(hash_table));
    memset(&global_variables, 0, sizeof(hash_table));

    interned_symbols.hashfn = hash;
    interned_symbols.equalfn = Fequal;

    global_variables.hashfn = fasthash;
    global_variables.equalfn = Feq;

    setup_builtins();

    while (1) {
        if (repl) {
            printf(">>> ");
        }
        if (yyparse()) {
            goto handle_error;
        }
        if (eof) {
            break;
        }

        object res = eval(parsed);
        if (current_signal) {
            goto handle_error;
        }
        if (repl) {
            Fprint(res);
        }

    handle_error:
        if (current_signal) {
            printf("ERROR: %s\n", XSTRING(Fstringify(current_signal)));
            current_signal = NULL;
            if (!repl) {
                return 1;
            }
            yyclearin;
        }
    }
}

/* Called by yyparse on error.  */
void yyerror(char const *s) {
    signal(intern("invalid-syntax"), make_string(s, strlen(s)));
}
