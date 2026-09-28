// Small native recovery journal. Build with `make native`; the launcher keeps
// the Python implementation as a fallback on systems without a C toolchain.
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_BYTES 262144

static struct json_object *obj(void) { return json_object_new_object(); }
static void putstr(struct json_object *o, const char *k, const char *v) {
    json_object_object_add(o, k, json_object_new_string(v ? v : ""));
}
static void putnum(struct json_object *o, const char *k, int64_t v) {
    json_object_object_add(o, k, json_object_new_int64(v));
}
static int emit(struct json_object *o, int rc) {
    puts(json_object_to_json_string_ext(o, JSON_C_TO_STRING_PLAIN));
    json_object_put(o);
    return rc;
}
static int error(const char *message) {
    struct json_object *o = obj(); putstr(o, "status", "error"); putstr(o, "error", message);
    return emit(o, 1);
}
static char *join(const char *dir, const char *name) {
    size_t n = strlen(dir) + strlen(name) + 2;
    char *s = malloc(n); if (s) snprintf(s, n, "%s/%s", dir, name);
    return s;
}
static char *absolute(const char *path) {
    if (path[0] == '/') return strdup(path);
    char *cwd = getcwd(NULL, 0); if (!cwd) return NULL;
    char *out = join(cwd, path); free(cwd); return out;
}
static int valid_utf8(const unsigned char *s, size_t n) {
    for (size_t i = 0; i < n;) {
        unsigned c = s[i++]; if (c < 0x80) continue;
        unsigned need, min;
        if (c >= 0xc2 && c <= 0xdf) { need = 1; min = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { need = 2; min = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { need = 3; min = 0x10000; }
        else return 0;
        if (i + need > n) return 0;
        unsigned code = c & (0x7f >> (need + 1));
        for (unsigned j = 0; j < need; j++) {
            unsigned b = s[i++]; if ((b & 0xc0) != 0x80) return 0;
            code = (code << 6) | (b & 0x3f);
        }
        if (code < min || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return 0;
    }
    return 1;
}
typedef struct { const unsigned char *s; size_t n, i; } Parser;
static void ws(Parser *p) { while (p->i < p->n && (p->s[p->i] == ' ' || p->s[p->i] == '\n' || p->s[p->i] == '\r' || p->s[p->i] == '\t')) p->i++; }
static int string(Parser *p) {
    if (p->i >= p->n || p->s[p->i++] != '"') return 0;
    while (p->i < p->n) {
        unsigned c = p->s[p->i++];
        if (c == '"') return 1;
        if (c < 0x20) return 0;
        if (c != '\\') continue;
        if (p->i >= p->n) return 0;
        c = p->s[p->i++];
        if (strchr("\"\\/bfnrt", c)) continue;
        if (c != 'u' || p->i + 4 > p->n) return 0;
        for (int j = 0; j < 4; j++) if (!isxdigit(p->s[p->i++])) return 0;
    }
    return 0;
}
static int value(Parser *p, int depth) {
    if (depth > 256) return 0;
    ws(p); if (p->i >= p->n) return 0;
    unsigned c = p->s[p->i];
    if (c == '"') return string(p);
    if (c == '{' || c == '[') {
        p->i++; ws(p);
        unsigned end = c == '{' ? '}' : ']';
        if (p->i < p->n && p->s[p->i] == end) { p->i++; return 1; }
        for (;;) {
            if (c == '{') { if (!string(p)) return 0; ws(p); if (p->i >= p->n || p->s[p->i++] != ':') return 0; }
            if (!value(p, depth + 1)) return 0;
            ws(p); if (p->i >= p->n) return 0;
            if (p->s[p->i] == end) { p->i++; return 1; }
            if (p->s[p->i++] != ',') return 0;
            ws(p);
        }
    }
    const char *lit = c == 't' ? "true" : c == 'f' ? "false" : c == 'n' ? "null" : NULL;
    if (lit) { size_t len = strlen(lit); if (p->i + len > p->n || memcmp(p->s + p->i, lit, len)) return 0; p->i += len; return 1; }
    if (c == '-') { p->i++; if (p->i >= p->n) return 0; }
    if (p->s[p->i] == '0') p->i++;
    else if (p->s[p->i] >= '1' && p->s[p->i] <= '9') {
        do { p->i++; } while (p->i < p->n && isdigit(p->s[p->i]));
    } else return 0;
    if (p->i < p->n && p->s[p->i] == '.') {
        p->i++; if (p->i >= p->n || !isdigit(p->s[p->i])) return 0;
        do { p->i++; } while (p->i < p->n && isdigit(p->s[p->i]));
    }
    if (p->i < p->n && (p->s[p->i] == 'e' || p->s[p->i] == 'E')) {
        p->i++; if (p->i < p->n && (p->s[p->i] == '+' || p->s[p->i] == '-')) p->i++;
        if (p->i >= p->n || !isdigit(p->s[p->i])) return 0;
        do { p->i++; } while (p->i < p->n && isdigit(p->s[p->i]));
    }
    return 1;
}
static int strict_json(const char *text, size_t n) {
    Parser p = { (const unsigned char *)text, n, 0 };
    if (!value(&p, 0)) return 0;
    ws(&p); return p.i == n;
}
static const char *dir_kind(const char *dir) {
    struct stat st;
    if (lstat(dir, &st) < 0) return errno == ENOENT ? NULL : "irregular";
    if (S_ISLNK(st.st_mode)) return "symlink";
    if (!S_ISDIR(st.st_mode) || st.st_uid != getuid()) return "irregular";
    return NULL;
}
static const char *file_kind(int dfd) {
    struct stat st;
    if (dfd < 0 || fstatat(dfd, "state.json", &st, AT_SYMLINK_NOFOLLOW) < 0)
        return errno == ENOENT ? "missing" : "irregular";
    if (S_ISLNK(st.st_mode)) return "symlink";
    if (!S_ISREG(st.st_mode) || st.st_uid != getuid()) return "irregular";
    if (st.st_size > MAX_BYTES) return "oversized";
    return "ok";
}
static int open_dir(const char *dir) { return open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); }
static int make_dir(const char *dir) {
    char *copy = strdup(dir); if (!copy) return -1;
    for (char *p = copy + 1; *p; p++) {
        if (*p == '/') { *p = 0; if (mkdir(copy, 0700) < 0 && errno != EEXIST) { free(copy); return -1; } *p = '/'; }
    }
    if (mkdir(copy, 0700) < 0 && errno != EEXIST) { free(copy); return -1; }
    free(copy);
    if (dir_kind(dir)) { errno = ELOOP; return -1; }
    if (chmod(dir, 0700) < 0) return -1;
    return 0;
}
static int status_text(const char *status, const char *path, const char *text, size_t len) {
    struct json_object *o = obj(); putstr(o, "status", status);
    json_object_object_add(o, "text", json_object_new_string_len(text, (int)len));
    putstr(o, "path", path); return emit(o, 0);
}
static char *read_file(const char *dir, char **path, const char **status, size_t *len) {
    *path = join(dir, "state.json"); *len = 0;
    *status = dir_kind(dir); if (*status) return NULL;
    int dfd = open_dir(dir);
    if (dfd < 0) { *status = errno == ENOENT ? "empty" : "irregular"; return NULL; }
    *status = file_kind(dfd);
    if (!strcmp(*status, "missing")) { *status = "empty"; close(dfd); return NULL; }
    if (strcmp(*status, "ok")) { close(dfd); return NULL; }
    int fd = openat(dfd, "state.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    close(dfd);
    if (fd < 0) { *status = errno == ELOOP ? "symlink" : "irregular"; return NULL; }
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()) {
        close(fd); *status = "irregular"; return NULL;
    }
    char *buf = malloc(MAX_BYTES + 2); if (!buf) { close(fd); *status = "irregular"; return NULL; }
    size_t n = 0;
    while (n <= MAX_BYTES) {
        ssize_t got = read(fd, buf + n, MAX_BYTES + 1 - n);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { close(fd); free(buf); *status = "irregular"; return NULL; }
        if (!got) break;
        n += (size_t)got;
    }
    close(fd);
    if (n > MAX_BYTES) { free(buf); *status = "oversized"; return NULL; }
    if (!valid_utf8((unsigned char *)buf, n)) { free(buf); *status = "invalid"; return NULL; }
    buf[n] = 0; *len = n; return buf;
}
static int do_read(const char *dir) {
    char *path, *buf; const char *status; size_t len;
    buf = read_file(dir, &path, &status, &len);
    int rc = status_text(buf ? "ok" : status, path, buf ? buf : "", buf ? len : 0);
    free(buf); free(path); return rc;
}
static int write_all(int fd, const char *buf, size_t n) {
    while (n) { ssize_t k = write(fd, buf, n); if (k <= 0) return -1; buf += k; n -= (size_t)k; }
    return 0;
}
static int do_write(const char *dir) {
    char buf[MAX_BYTES + 2]; size_t n = 0;
    while (n <= MAX_BYTES) {
        ssize_t k = read(STDIN_FILENO, buf + n, MAX_BYTES + 1 - n);
        if (k < 0) return error("read failed");
        if (!k) break;
        n += (size_t)k;
    }
    if (n > MAX_BYTES) return error("document too large");
    if (!valid_utf8((unsigned char *)buf, n)) return error("document is not UTF-8");
    if (!strict_json(buf, n)) return error("document is not JSON");
    // json-c needs a delimiter after top-level scalars such as `1` or `null`.
    buf[n] = ' ';
    struct json_tokener *tok = json_tokener_new();
    json_tokener_set_flags(tok, JSON_TOKENER_STRICT);
    struct json_object *doc = json_tokener_parse_ex(tok, buf, (int)n + 1);
    enum json_tokener_error parse_error = json_tokener_get_error(tok);
    int parsed = json_tokener_get_parse_end(tok);
    while (parsed < (int)n + 1 && isspace((unsigned char)buf[parsed])) parsed++;
    int valid = parse_error == json_tokener_success && parsed == (int)n + 1;
    json_object_put(doc); json_tokener_free(tok);
    if (!valid) return error("document is not JSON");
    if (make_dir(dir) < 0) {
        const char *problem = dir_kind(dir);
        if (problem) { char msg[80]; snprintf(msg, sizeof(msg), "state directory is %s", problem); return error(msg); }
        return error("mkdir failed");
    }
    int dfd = open_dir(dir); if (dfd < 0) return error("state directory is irregular");
    const char *kind = file_kind(dfd);
    if (!strcmp(kind, "symlink") || !strcmp(kind, "irregular")) {
        char *path = join(dir, "state.json"); char msg[PATH_MAX + 80];
        snprintf(msg, sizeof(msg), "refusing to replace %s at %s", kind, path); free(path); close(dfd); return error(msg);
    }
    char tmp[128]; snprintf(tmp, sizeof(tmp), ".state.json.%ld.%ld.tmp", (long)getpid(), (long)time(NULL));
    int fd = openat(dfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { close(dfd); return error("open temp failed"); }
    int ok = write_all(fd, buf, n) == 0;
    if (ok && (n == 0 || buf[n-1] != '\n')) ok = write_all(fd, "\n", 1) == 0;
    if (ok) ok = fsync(fd) == 0;
    if (close(fd) < 0) ok = 0;
    if (ok) ok = renameat(dfd, tmp, dfd, "state.json") == 0;
    if (ok) (void)fsync(dfd);
    if (!ok) unlinkat(dfd, tmp, 0);
    close(dfd);
    if (!ok) return error("write failed");
    char *path = join(dir, "state.json"); struct json_object *o = obj();
    putstr(o, "status", "ok"); putstr(o, "path", path); putnum(o, "bytes", (int64_t)n);
    free(path); return emit(o, 0);
}
static int do_quarantine(const char *dir, const char *reason) {
    const char *problem = dir_kind(dir);
    if (problem) { char msg[80]; snprintf(msg, sizeof(msg), "state directory is %s", problem); return error(msg); }
    int dfd = open_dir(dir);
    if (dfd < 0 && errno == ENOENT) { struct json_object *empty = obj(); putstr(empty, "status", "empty"); return emit(empty, 0); }
    if (dfd < 0) return error("state directory is irregular");
    const char *kind = file_kind(dfd); struct json_object *o = obj();
    if (!strcmp(kind, "missing")) { close(dfd); putstr(o, "status", "empty"); return emit(o, 0); }
    if (!strcmp(kind, "symlink")) {
        int rc = unlinkat(dfd, "state.json", 0); close(dfd);
        if (rc < 0) { json_object_put(o); return error("unlink failed"); }
        putstr(o, "status", "removed"); putstr(o, "kind", kind); return emit(o, 0);
    }
    char safe[33]; size_t j = 0;
    for (size_t i = 0; reason && reason[i] && j < 32; i++)
        if (isalnum((unsigned char)reason[i]) || reason[i] == '-' || reason[i] == '_') safe[j++] = reason[i];
    if (!j) memcpy(safe, "damaged", 7), j = 7;
    safe[j] = 0;
    char name[128]; snprintf(name, sizeof(name), "state.json.%s.%ld.%ld", safe, (long)time(NULL), (long)getpid());
    int rc = renameat(dfd, "state.json", dfd, name); close(dfd);
    if (rc < 0) { json_object_put(o); return error("rename failed"); }
    char *target = join(dir, name); putstr(o, "status", "ok"); putstr(o, "moved_to", target);
    putstr(o, "kind", kind); free(target); return emit(o, 0);
}
static int do_inspect(const char *dir) {
    char *path, *buf; const char *status; size_t len;
    buf = read_file(dir, &path, &status, &len);
    struct json_object *o = obj(); putstr(o, "status", buf ? "ok" : status);
    putstr(o, "path", path); putnum(o, "entries", 0); putstr(o, "session", "");
    json_object_object_add(o, "schema", NULL);
    if (buf) {
        buf[len] = ' ';
        struct json_tokener *tok = json_tokener_new();
        json_tokener_set_flags(tok, JSON_TOKENER_STRICT);
        struct json_object *doc = json_tokener_parse_ex(tok, buf, (int)len + 1), *schema, *entries, *session;
        int parsed = json_tokener_get_parse_end(tok);
        while (parsed < (int)len + 1 && isspace((unsigned char)buf[parsed])) parsed++;
        int valid = json_tokener_get_error(tok) == json_tokener_success && parsed == (int)len + 1;
        json_tokener_free(tok);
        if (!valid || !strict_json(buf, len) || !doc || !json_object_is_type(doc, json_type_object) ||
            !json_object_object_get_ex(doc, "schema", &schema) || json_object_get_int(schema) != 1 ||
            !json_object_object_get_ex(doc, "entries", &entries) || !json_object_is_type(entries, json_type_array)) {
            putstr(o, "status", "invalid");
        } else {
            json_object_object_add(o, "schema", json_object_new_int(1));
            int count = json_object_array_length(entries); putnum(o, "entries", count);
            const char *s = "";
            if (json_object_object_get_ex(doc, "session", &session) && session) s = json_object_get_string(session);
            putstr(o, "session", s);
            struct json_object *addresses = json_object_new_array();
            for (int i = 0; i < count && i < 64; i++) {
                struct json_object *entry = json_object_array_get_idx(entries, i), *address;
                if (!json_object_is_type(entry, json_type_object)) continue;
                const char *a = "";
                if (json_object_object_get_ex(entry, "address", &address) && address) a = json_object_get_string(address);
                json_object_array_add(addresses, json_object_new_string(a));
            }
            json_object_object_add(o, "addresses", addresses);
            const char *current = getenv("HYPRLAND_INSTANCE_SIGNATURE");
            json_object_object_add(o, "current_session", current && *current ? json_object_new_boolean(!strcmp(current, s)) : NULL);
        }
        json_object_put(doc);
    }
    free(buf); free(path); return emit(o, 0);
}
int main(int argc, char **argv) {
    const char *action = NULL, *dir = NULL, *reason = "damaged";
    if (argc > 1) action = argv[1];
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--state-dir") && i + 1 < argc) dir = argv[++i];
        else if (!strcmp(argv[i], "--reason") && i + 1 < argc) reason = argv[++i];
        else return error("invalid arguments");
    }
    char *default_dir = NULL;
    if (!dir) {
        const char *base = getenv("XDG_STATE_HOME");
        if (!base || !*base) {
            const char *home = getenv("HOME"); if (!home) return error("HOME is unset");
            base = default_dir = join(home, ".local/state");
        }
        dir = join(base, "reprieve"); free(default_dir); default_dir = (char *)dir;
    }
    char *absdir = absolute(dir); free(default_dir);
    if (!absdir) return error("invalid state directory");
    int rc;
    if (action && !strcmp(action, "read")) rc = do_read(absdir);
    else if (action && !strcmp(action, "write")) rc = do_write(absdir);
    else if (action && !strcmp(action, "quarantine")) rc = do_quarantine(absdir, reason);
    else if (action && !strcmp(action, "inspect")) rc = do_inspect(absdir);
    else rc = error("invalid action");
    free(absdir); return rc;
}
