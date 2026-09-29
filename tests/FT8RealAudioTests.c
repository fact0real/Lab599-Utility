// Decodes the real FT8 recordings shipped with kgoba/ft8_lib (test/wav and
// test/wav/20m_busy, each with a reference list of decodes) and fails if
// the decoder finds fewer reference messages than the baseline.
// Run through tests/run-ft8-real-audio-tests.sh, which fetches the data.

#include "tx500_ft8_shim.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define BASELINE_FOUND 956   // reference decodes found at commit bcec0b2 (60 recordings)
#define MAX_MESSAGES 128
#define MESSAGE_LENGTH 64
#define MAX_FILES 256

typedef struct {
    char text[MAX_MESSAGES][MESSAGE_LENGTH];
    int count;
} message_list_t;

typedef struct {
    int reference, found, extra, recordings;
} totals_t;

// Collapse runs of spaces so "CQ  EA3XX" and "CQ EA3XX" compare equal.
static void normalize(const char *in, char *out, size_t size) {
    size_t n = 0;
    int space = 1;
    for (; *in && n + 1 < size; ++in) {
        if (*in == ' ' || *in == '\t' || *in == '\r' || *in == '\n') {
            if (!space) out[n++] = ' ';
            space = 1;
        } else {
            out[n++] = *in;
            space = 0;
        }
    }
    while (n > 0 && out[n - 1] == ' ') n--;
    out[n] = '\0';
}

static void add_unique(message_list_t *list, const char *text) {
    if (!text[0] || list->count >= MAX_MESSAGES) return;
    for (int i = 0; i < list->count; ++i)
        if (strcmp(list->text[i], text) == 0) return;
    snprintf(list->text[list->count++], MESSAGE_LENGTH, "%s", text);
}

// Reference lines look like "000000 -17 -0.6  309 ~  G4CUS SP4FCA +10".
// Some end with a country name separated by two or more spaces.
static void load_reference(const char *path, message_list_t *list) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *tilde = strchr(line, '~');
        if (!tilde) continue;
        char *msg = tilde + 1;
        while (*msg == ' ') msg++;
        char *end = strstr(msg, "  ");
        if (end) *end = '\0';
        char clean[MESSAGE_LENGTH];
        normalize(msg, clean, sizeof clean);
        add_unique(list, clean);
    }
    fclose(f);
}

static int has_suffix(const char *name, const char *suffix) {
    size_t a = strlen(name), b = strlen(suffix);
    return a >= b && strcmp(name + a - b, suffix) == 0;
}

static int compare_names(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

// Decode one recording in a child process: the decoder keeps a callsign
// hash cache between calls, and the recordings are unrelated.
static int decode_recording(const char *wav, message_list_t *decoded) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }
    if (pid == 0) {
        close(fds[0]);
        ft8808_decoded_t out[100];
        int n = ft8808_decode_wav(wav, FT8808_PROTOCOL_FT8, out, 100);
        FILE *w = fdopen(fds[1], "w");
        if (n < 0 || !w) _exit(1);
        for (int k = 0; k < n; ++k) fprintf(w, "%s\n", out[k].text);
        fclose(w);
        _exit(0);
    }
    close(fds[1]);
    FILE *r = fdopen(fds[0], "r");
    char line[MESSAGE_LENGTH];
    while (r && fgets(line, sizeof line, r)) {
        char clean[MESSAGE_LENGTH];
        normalize(line, clean, sizeof clean);
        add_unique(decoded, clean);
    }
    if (r) fclose(r);
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return -1;
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
}

// Decodes every .wav with a .txt reference in one directory.
static int decode_directory(const char *directory, totals_t *totals) {
    DIR *dir = opendir(directory);
    if (!dir) {
        fprintf(stderr, "cannot open %s\n", directory);
        return 2;
    }
    char *names[MAX_FILES];
    int files = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) && files < MAX_FILES)
        if (has_suffix(entry->d_name, ".txt")) names[files++] = strdup(entry->d_name);
    closedir(dir);
    qsort(names, (size_t)files, sizeof names[0], compare_names);

    int result = 0;
    for (int i = 0; i < files && result == 0; ++i) {
        char txt[1024], wav[1024];
        snprintf(txt, sizeof txt, "%s/%s", directory, names[i]);
        snprintf(wav, sizeof wav, "%s/%.*s.wav", directory, (int)(strlen(names[i]) - 4), names[i]);
        FILE *probe = fopen(wav, "rb");
        if (!probe) continue;
        fclose(probe);

        message_list_t reference = {0}, decoded = {0};
        load_reference(txt, &reference);
        if (decode_recording(wav, &decoded) != 0) {
            fprintf(stderr, "FAIL: could not decode %s\n", wav);
            result = 1;
            break;
        }
        int found = 0;
        for (int r = 0; r < reference.count; ++r)
            for (int d = 0; d < decoded.count; ++d)
                if (strcmp(reference.text[r], decoded.text[d]) == 0) { found++; break; }
        int extra = decoded.count - found;
        printf("  %-24s reference=%3d found=%3d extra=%2d\n", names[i], reference.count, found, extra);
        totals->reference += reference.count;
        totals->found += found;
        totals->extra += extra;
        totals->recordings++;
    }
    for (int i = 0; i < files; ++i) free(names[i]);
    return result;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <directory with .wav and .txt pairs> ...\n", argv[0]);
        return 2;
    }
    totals_t totals = {0};
    for (int i = 1; i < argc; ++i) {
        int result = decode_directory(argv[i], &totals);
        if (result != 0) return result;
    }

    printf("Real-audio FT8: %d/%d reference decodes found (%.1f%%), %d not in reference, %d recordings\n",
           totals.found, totals.reference,
           totals.reference ? 100.0 * totals.found / totals.reference : 0.0,
           totals.extra, totals.recordings);
    if (totals.recordings != 60 || totals.reference != 1289 || totals.found < BASELINE_FOUND) {
        fprintf(stderr, "FAIL: expected 60 recordings, 1289 reference decodes and at least %d matches\n", BASELINE_FOUND);
        return 1;
    }
    printf("Real-audio FT8 regression test passed (baseline %d)\n", BASELINE_FOUND);
    return 0;
}
