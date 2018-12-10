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
    T_BUILTIN,                  /* Built-in function. */
    T_LAMBDA,                   /* Lambda function. */
} object_type_t;

struct builtin {
    object (*dispatch_fn)(void *fnptr, object args);
    void *ptr;
    const char *name;
};

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
        struct lambda *lambda;
        struct builtin *builtin;
    };
    object_type_t type;
    int gcbits;
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

#define GC_UNVISITED 0
#define GC_DELETE 1
#define GC_KEEP 2

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

/* Check if OBJ is of given TYPE.  Return 1 on success, 0 and signal
 * an error on failure. */
int assert_type(object obj, object_type_t type) {
    const char *type_string;
    switch (type) {
    case T_BUILTIN:
        type_string = "builtin-function-p";
        break;
    case T_SYMBOL:
        type_string = "symbolp";
        break;
    case T_STRING:
        type_string = "stringp";
        break;
    case T_FIXNUM:
        type_string = "numberp";
        break;
    case T_CONS:
        type_string = "consp";
        break;
    case T_LAMBDA:
        type_string = "functionp";
        break;
    default:
        error("assert_type");
    }

    if (NILP(obj)) {
        signal(intern("wrong-type-argument"),
               make_cons(intern(type_string), NULL));
        return 0;
    }
    if (obj->type != type) {
        signal(intern("wrong-type-argument"),
               make_cons(intern(type_string), obj));
        return 0;
    }

    return 1;
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

    object obj = calloc(1, sizeof(struct lisp_object));
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


/* Lookup */

hash_table interned_symbols;
hash_table global_variables;
hash_table local_variables;

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

void push_local_variable(object sym, object value) {
    object *elt = hash_get(&local_variables, sym);
    if (!elt) {
        object cons = make_cons(value, NULL);
        hash_put(&local_variables, sym, cons);
        return;
    }

    *elt = make_cons(value, *elt);
}

void pop_local_variable(object sym) {
    object *elt = hash_get(&local_variables, sym);
    if (!elt) {
        error("pop_local_variable: missing");
    }
    *elt = XCDR(*elt);
}

object *lookup(object sym, int create) {
    if (!SYMBOLP(sym)) {
        error("lookup: trying to lookup non-symbol");
    }

    object *res = hash_get(&local_variables, sym);
    if (res != NULL && !NILP(*res)) {
        return &(*res)->car;
    }

    res = hash_get(&global_variables, sym);
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
    object res = NULL;
    int nvars = 0;
    object lambda_symbol = lambda->argumentlist;

    while (CONSP(args)) {
        if (NILP(lambda_symbol)) {
            signal(intern("wrong-number-of-arguments"), NULL);
            goto cleanup;
        }
        object arg = eval(XCAR(args));
        if (!NILP(current_signal)) {
            goto cleanup;
        }

        push_local_variable(XCAR(lambda_symbol), arg);
        nvars++;

        lambda_symbol = XCDR(lambda_symbol);
        args = XCDR(args);
    }
    if (CONSP(lambda_symbol)) {
        signal(intern("wrong-number-of-arguments"), NULL);
        goto cleanup;
    }

    object body = lambda->body;
    while (CONSP(body)) {
        res = eval(XCAR(body));
        if (!NILP(current_signal)) {
            break;
        }
        body = XCDR(body);
    }

cleanup:
    lambda_symbol = lambda->argumentlist;
    while (nvars-- > 0) {
        pop_local_variable(XCAR(lambda_symbol));
        lambda_symbol = XCDR(lambda_symbol);
    }
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
        if (function->type == T_BUILTIN) {
            struct builtin *builtin = function->builtin;
            return builtin->dispatch_fn(builtin->ptr, args);
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
    case T_BUILTIN:
        return obj;
    }

    error("eval");
}


/* Garbage collector. */

void free_object(object obj) {
    if (NILP(obj)) {
        return;
    } else if (STRINGP(obj)) {
        free(XSTRING(obj));
    } else if (SYMBOLP(obj)) {
        free(XSYMBOL(obj));
    } else if (obj->type == T_LAMBDA) {
        free(obj->lambda);
    }

    free(obj);
}

void mark_object(object obj, int flag) {
    if (NILP(obj) || obj->gcbits == flag) {
        return;
    }

    obj->gcbits = flag;

    if (CONSP(obj)) {
        mark_object(XCAR(obj), flag);
        mark_object(XCDR(obj), flag);
    } else if (obj->type == T_LAMBDA) {
        mark_object(obj->lambda->body, flag);
        mark_object(obj->lambda->argumentlist, flag);
    }
}

void garbage_collect() {
    /* Mark all objects */
    for (int i = 0; i < nobjects; i++) {
        if (!NILP(objects[i])) {
            objects[i]->gcbits = GC_DELETE;
        }
    }

    for (int i = 0; i < interned_symbols.nbuckets; i++) {
        object var = interned_symbols.buckets[i];
        mark_object(var, GC_KEEP);
    }

    for (int i = 0; i < global_variables.nbuckets; i++) {
        object var = global_variables.buckets[i];
        mark_object(var, GC_KEEP);
    }

    for (int i = 0; i < local_variables.nbuckets; i++) {
        object var = local_variables.buckets[i];
        mark_object(var, GC_KEEP);
    }

    mark_object(parsed, GC_KEEP);
    mark_object(t, GC_KEEP);

    size_t after_deletion = 0;
    for (int i = 0; i < nobjects; i++) {
        if (NILP(objects[i])) {
            continue;
        }
        if (objects[i]->gcbits == GC_DELETE) {
            free_object(objects[i]);
            objects[i] = NULL;
        } else {
            after_deletion++;
        }
    }

    object *newobjects = malloc(after_deletion * sizeof(*objects));
    for (int i = 0, j = 0; i < nobjects; i++) {
        if (!NILP(objects[i])) {
            newobjects[j++] = objects[i];
        }
    }

    capacity = after_deletion;
    free(objects);
    objects = newobjects;
    nobjects = after_deletion;
}


/* Built-in functions. */

/* Helpers for dispatching */
#define ARGLIST_0 ()
#define ARGLIST_1 (object)
#define ARGLIST_2 (object, object)
#define ARGLIST_MANY (object)

#define DEFINE_BUILTIN(lisp_name, struct_name, function_name, nargs,           \
                       dispatch_function)                                      \
    object function_name ARGLIST_##nargs;                                      \
    struct builtin struct_name = {.dispatch_fn = dispatch_function,            \
                                  .ptr = function_name,                        \
                                  .name = lisp_name};                          \
    object function_name

#define DEFUN(lisp_name, struct_name, function_name, nargs)                    \
    DEFINE_BUILTIN(lisp_name, struct_name, function_name, nargs,               \
                   dispatch_##nargs)

#define DEFMACRO(lisp_name, struct_name, function_name, nargs)                 \
    DEFINE_BUILTIN(lisp_name, struct_name, function_name, nargs,               \
                   dispatch_unevalled_##nargs)

int assert_argument_count(object cons, ptrdiff_t expected_len) {
    ptrdiff_t len = length(cons);
    if (len != expected_len) {
        signal(intern("wrong-number-of-arguments"),
               make_cons(make_fixnum(expected_len), make_fixnum(len)));
        return 0;
    }
    return 1;
}

#define ASSERT_ARGUMENT_COUNT(cons, nargs)                                     \
    do {                                                                       \
        if (!assert_argument_count(cons, nargs))                               \
            return NULL;                                                       \
    } while (false);

object dispatch_0(void *fnptr, object args) {
    ASSERT_ARGUMENT_COUNT(args, 0);

    object (*fn)() = fnptr;
    return fn();
}

object dispatch_1(void *fnptr, object args) {
    ASSERT_ARGUMENT_COUNT(args, 1);

    object (*fn)(object) = fnptr;

    object arg = eval(XCAR(args));
    if (!NILP(current_signal)) {
        return NULL;
    }

    return fn(arg);
}

object dispatch_unevalled_1(void *fnptr, object args) {
    ASSERT_ARGUMENT_COUNT(args, 1);

    object (*fn)(object) = fnptr;

    return fn(XCAR(args));
}

object dispatch_2(void *fnptr, object args) {
    ASSERT_ARGUMENT_COUNT(args, 2);

    object (*fn)(object, object) = fnptr;

    object arg1 = eval(XCAR(args));
    if (!NILP(current_signal)) {
        return NULL;
    }

    object arg2 = eval(XCAR(XCDR(args)));
    if (!NILP(current_signal)) {
        return NULL;
    }

    return fn(arg1, arg2);
}

object dispatch_MANY(void *fnptr, object args) {
    object (*fn)(object) = fnptr;

    object evaluated_arg = NULL;
    object evaluated_arglist = NULL;
    while (CONSP(args)) {
        object arg = eval(XCAR(args));
        args = XCDR(args);
        if (!NILP(current_signal)) {
            return NULL;
        }
        if (NILP(evaluated_arg)) {
            evaluated_arg = evaluated_arglist = make_cons(arg, NULL);
        } else {
            evaluated_arg->cdr = make_cons(arg, NULL);
            evaluated_arg = XCDR(evaluated_arg);
        }
    }

    return fn(evaluated_arglist);
}

object dispatch_unevalled_MANY(void *fnptr, object args) {
    object (*fn)(object) = fnptr;
    return fn(args);
}

/* Builtins */

DEFMACRO("quote", Squote, Fquote, 1)
(object arg) { return arg; }

DEFMACRO("progn", Sprogn, Fprogn, MANY)
(object args) {
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

DEFUN("set", Sset, Fset, 2)
(object symbol, object value) {
    if (!assert_type(symbol, T_SYMBOL)) {
        return NULL;
    }

    object *ptr = lookup(symbol, 1);
    *ptr = value;

    return value;
}

DEFUN("not", Snot, Fnot, 1)
(object arg) {
    if (NILP(arg)) {
        return intern("t");
    }
    return NULL;
}

DEFUN("length", Slength, Flength, 1)
(object sequence) {
    ptrdiff_t len = length(sequence);
    if (len < 0) {
        signal(intern("wrong-type-argument"),
               make_cons(intern("listp"), sequence));
        return NULL;
    }
    return make_fixnum(len);
}

DEFUN("cons", Scons, Fcons, 2)
(object car, object cdr) { return make_cons(car, cdr); }

DEFUN("concat", Sconcat, Fconcat, 2)
(object obj1, object obj2) { return concat(obj1, obj2); }

DEFUN("car", Scar, Fcar, 1)
(object arg) {
    if (!NILP(arg) && !assert_type(arg, T_CONS)) {
        return NULL;
    }

    return XCAR(arg);
}

DEFUN("cdr", Scdr, Fcdr, 1)
(object arg) {
    if (!NILP(arg) && !assert_type(arg, T_CONS)) {
        return NULL;
    }

    return XCDR(arg);
}

DEFUN("stringify", Sstringify, Fstringify, 1)
(object obj) {
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
    case T_BUILTIN: {
        char s[128];
        sprintf(s, "builtin function %s", obj->builtin->name);
        return make_string(s, strlen(s));
    }
    case T_LAMBDA:
        return make_string("lambda", 6);
    default:
        error("stringify: unknown type %d", obj->type);
    }
}

DEFMACRO("lambda", Slambda, Flambda, MANY)
(object args) {
    if (!NILP(XCAR(args)) && !assert_type(XCAR(args), T_CONS)) {
        return NULL;
    }

    object body = XCDR(args);
    object arg = XCAR(args);
    object arglist = arg;
    while (CONSP(arg)) {
        if (!assert_type(XCAR(arg), T_SYMBOL)) {
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

DEFMACRO("let", Slet, Flet, MANY)
(object args) {
    if (!CONSP(XCAR(args)) && !NILP(XCAR(args))) {
        signal(intern("wrong-type-argument"), intern("consp"));
        return NULL;
    }

    object result = NULL;
    object arglist = XCAR(args);
    object body = XCDR(args);
    int nvars = 0;

    while (CONSP(arglist)) {
        object elt = XCAR(arglist);
        if (!CONSP(elt)) {
            signal(intern("lisp-error"), make_cons(intern("consp"), elt));
            goto cleanup;
        }
        if (!SYMBOLP(XCAR(elt))) {
            signal(intern("lisp-error"),
                   make_cons(intern("symbolp"), XCAR(elt)));
            goto cleanup;
        }
        if (!CONSP(XCDR(elt))) {
            signal(intern("lisp-error"), NULL);
            goto cleanup;
        }
        if (!NILP(XCDR(XCDR(elt)))) {
            signal(intern("lisp-error"), NULL);
            goto cleanup;
        }

        object symbol = XCAR(elt);
        object value = eval(XCAR(XCDR(elt)));
        if (!NILP(current_signal)) {
            goto cleanup;
        }

        push_local_variable(symbol, value);
        nvars++;
        arglist = XCDR(arglist);
    }

    result = Fprogn(body);

cleanup:
    arglist = XCAR(args);
    while (nvars--) {
        pop_local_variable(XCAR(XCAR(arglist)));
        arglist = XCDR(arglist);
    }
    return result;
}

DEFUN("+", Splus, Fplus, MANY)
(object args) {
    int ret = 0;

    while (CONSP(args)) {
        object val = XCAR(args);
        if (!assert_type(XCAR(args), T_FIXNUM)) {
            return NULL;
        }
        ret += XINT(val);
        args = XCDR(args);
    }

    return make_fixnum(ret);
}

DEFUN("-", Sminus, Fminus, MANY)
(object args) {
    int ret = 0;

    if (CONSP(args)) {
        if (!assert_type(XCAR(args), T_FIXNUM)) {
            return NULL;
        }
        ret = XINT(XCAR(args));
        args = XCDR(args);
        if (!CONSP(args)) {
            ret = -ret;
        }
    }

    while (CONSP(args)) {
        object val = XCAR(args);
        if (!assert_type(XCAR(args), T_FIXNUM)) {
            return NULL;
        }
        ret -= XINT(val);
        args = XCDR(args);
    }

    return make_fixnum(ret);
}

DEFUN("*", Smultiply, Fmultiply, MANY)
(object args) {
    int ret = 1;

    while (CONSP(args)) {
        object val = XCAR(args);
        if (!assert_type(XCAR(args), T_FIXNUM)) {
            return NULL;
        }
        ret *= XINT(val);
        args = XCDR(args);
    }

    return make_fixnum(ret);
}

DEFUN("<", Sless, Fless, 2)
(object number1, object number2) {
    if (!assert_type(number1, T_FIXNUM) || !assert_type(number2, T_FIXNUM)) {
        return NULL;
    }
    if (XINT(number1) < XINT(number2)) {
        return intern("t");
    }
    return NULL;
}

DEFUN("eq", Seq, Feq, 2)
(object obj1, object obj2) {
    int res;
    if (FIXNUMP(obj1) && FIXNUMP(obj2)) {
        res = XINT(obj1) == XINT(obj2);
    } else {
        res = obj1 == obj2;
    }
    return res == 0 ? NULL : t;
}

DEFUN("equal", Sequal, Fequal, 2)
(object obj1, object obj2) {
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

DEFMACRO("if", Sif, Fif, MANY)
(object args) {
    object cond = eval(XCAR(args));

    if (!NILP(current_signal)) {
        return NULL;
    }

    if (!NILP(cond)) {
        return eval(XCAR(XCDR(args)));
    }

    return Fprogn(XCDR(XCDR(args)));
}

DEFMACRO("while", Swhile, Fwhile, MANY)
(object args) {
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

DEFUN("print", Sprint, Fprint, 1)
(object obj) {
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

DEFUN("garbage-collect", Sgarbage_collect, Fgarbage_collect, 0)() {
    garbage_collect();
    return NULL;
}


/* main */

void defsym(struct builtin* builtin) {
    object obj = alloc(T_BUILTIN);
    obj->builtin = builtin;
    Fset(intern(builtin->name), obj);
}

void setup_builtins() {
    t = make_fixnum(1);

    Fset(intern("nil"), NULL);

    Fset(intern("t"), intern("t"));
    t = intern("t");

    defsym(&Squote);
    defsym(&Sset);
    defsym(&Snot);
    defsym(&Slength);
    defsym(&Scons);
    defsym(&Sstringify);
    defsym(&Scar);
    defsym(&Scdr);

    defsym(&Slambda);
    defsym(&Slet);

    defsym(&Sprint);
    defsym(&Splus);
    defsym(&Sminus);
    defsym(&Smultiply);
    defsym(&Sless);
    defsym(&Sprogn);

    defsym(&Sif);
    defsym(&Swhile);
    defsym(&Seq);
    defsym(&Sequal);
    defsym(&Sgarbage_collect);
    defsym(&Sconcat);
}

int main(int argc, char **argv) {
    bool repl = argc > 1 && !strcmp(argv[1], "--repl");

    memset(&interned_symbols, 0, sizeof(hash_table));
    memset(&global_variables, 0, sizeof(hash_table));
    memset(&local_variables, 0, sizeof(hash_table));

    interned_symbols.hashfn = hash;
    interned_symbols.equalfn = Fequal;

    global_variables.hashfn = fasthash;
    global_variables.equalfn = Feq;

    local_variables.hashfn = fasthash;
    local_variables.equalfn = Feq;

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
        garbage_collect();

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
