// verify.m -- re-verify a database of people, one process per person.
//
// people.db holds 1,000 made-up people, all last verified in 2015. Each
// verification checks the email address's format and then waits 1-20 ms,
// standing in for asking a mail server. A verified person is stamped
// 2026; a failed one stays at 2015.
//
//     ./verify create     make people.db (1,000 people, 2015, some bad emails)
//     ./verify csp        one process per person; one writer process
//     ./verify linear     the same checks one after another
//     ./verify sql        a single UPDATE, no checks -- the fastest way
//                         when there is no work per record
//
// The shape: every verifier sends its result to one writer process, which
// owns the database connection and commits in batches -- SQLite has one
// writer at a time anyway, so a queue replaces "database is locked".

#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import <time.h>
#import "../CSP.h"

enum { PEOPLE = 1000, BATCH = 500 };

static const char *dbPath = "people.db";

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static sqlite3 *openDB(void) {
    sqlite3 *db;
    if (sqlite3_open(dbPath, &db) != SQLITE_OK) {
        fprintf(stderr, "verify: can't open %s\n", dbPath);
        exit(1);
    }
    return db;
}

static void exec(sqlite3 *db, const char *sql) {
    char *err = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "verify: %s: %s\n", sql, err);
        exit(1);
    }
}

static int countWhere(sqlite3 *db, const char *where) {
    sqlite3_stmt *st;
    NSString *sql = [NSString stringWithFormat:@"SELECT count(*) FROM people WHERE %s", where];
    sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL);
    sqlite3_step(st);
    int n = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
    return n;
}

static void create(void) {
    static const char *first[] = {"James", "Mary", "John", "Patricia", "Robert", "Jennifer", "Michael",
        "Linda", "David", "Elizabeth", "William", "Barbara", "Richard", "Susan", "Joseph", "Jessica",
        "Thomas", "Sarah", "Charles", "Karen", "Daniel", "Nancy", "Matthew", "Lisa", "Anthony"};
    static const char *last[] = {"Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
        "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson",
        "Thomas", "Taylor", "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson", "White", "Harris"};
    remove(dbPath);
    sqlite3 *db = openDB();
    exec(db, "CREATE TABLE people (uniqueid INTEGER PRIMARY KEY, lastname TEXT, firstname TEXT, "
             "emailAddress TEXT, lastVerified INTEGER)");
    exec(db, "BEGIN");
    sqlite3_stmt *st;
    sqlite3_prepare_v2(db, "INSERT INTO people VALUES (?, ?, ?, ?, 2015)", -1, &st, NULL);
    for (int i = 1; i <= PEOPLE; i++) {
        const char *f = first[i % 25], *l = last[(i / 25) % 25];
        NSString *email = [NSString stringWithFormat:@"%s.%s%d@example.com", f, l, i].lowercaseString;
        if (i % 20 == 0) email = [email stringByReplacingOccurrencesOfString:@"@" withString:@""];
        if (i % 33 == 0) email = [email stringByReplacingOccurrencesOfString:@".com" withString:@""];
        sqlite3_bind_int(st, 1, i);
        sqlite3_bind_text(st, 2, l, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 3, f, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 4, email.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(st);
        sqlite3_reset(st);
    }
    sqlite3_finalize(st);
    exec(db, "COMMIT");
    printf("created %s: %d people, last verified 2015\n", dbPath, countWhere(db, "lastVerified = 2015"));
    sqlite3_close(db);
}

@interface Person : NSObject
@property int uniqueid;
@property NSString *email;
@property BOOL ok;
@end

@implementation Person
@end

static NSArray<Person *> *loadPeople(sqlite3 *db) {
    NSMutableArray *people = [NSMutableArray new];
    sqlite3_stmt *st;
    sqlite3_prepare_v2(db, "SELECT uniqueid, emailAddress FROM people ORDER BY uniqueid", -1, &st, NULL);
    while (sqlite3_step(st) == SQLITE_ROW) {
        Person *p = [Person new];
        p.uniqueid = sqlite3_column_int(st, 0);
        p.email = @((const char *)sqlite3_column_text(st, 1));
        [people addObject:p];
    }
    sqlite3_finalize(st);
    return people;
}

// The check: one @, something before it, a dot in the part after it.
// Then a 1-20 ms wait, standing in for asking the mail server.
static BOOL verify(Person *p) {
    NSArray<NSString *> *parts = [p.email componentsSeparatedByString:@"@"];
    BOOL ok = parts.count == 2 && parts[0].length > 0 && [parts[1] containsString:@"."];
    sleepFor((1 + p.uniqueid * 37 % 20) / 1000.0);
    return ok;
}

// A process: verify one person and send the result to the writer.
void verifier(Person *p, Chan<Person *> *results) {
    p.ok = verify(p);
    [results send:p];
}

// The one process that writes. Takes every result, stamps the verified
// ones, and commits every BATCH updates; then reports how many it stamped.
void writer(int expected, Chan<Person *> *results, Chan<NSNumber *> *done) {
    sqlite3 *db = openDB();
    sqlite3_stmt *st;
    sqlite3_prepare_v2(db, "UPDATE people SET lastVerified = 2026 WHERE uniqueid = ?", -1, &st, NULL);
    int stamped = 0, inBatch = 0;
    exec(db, "BEGIN");
    for (int i = 0; i < expected; i++) {
        Person *p = [results receive];
        if (!p.ok) continue;
        sqlite3_bind_int(st, 1, p.uniqueid);
        sqlite3_step(st);
        sqlite3_reset(st);
        stamped++;
        if (++inBatch == BATCH) {
            exec(db, "COMMIT");
            exec(db, "BEGIN");
            inBatch = 0;
        }
    }
    exec(db, "COMMIT");
    sqlite3_finalize(st);
    sqlite3_close(db);
    [done send:@(stamped)];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *mode = argc > 1 ? argv[1] : "";
        if (!strcmp(mode, "create")) {
            create();
            return 0;
        }
        if (strcmp(mode, "csp") && strcmp(mode, "linear") && strcmp(mode, "sql")) {
            fprintf(stderr, "usage: verify create | csp | linear | sql\n");
            return 2;
        }
        if (sqlite3_threadsafe() == 0) {
            fprintf(stderr, "verify: this SQLite is single-threaded only\n");
            return 1;
        }

        // Every run starts from 2015, so the modes can be compared.
        sqlite3 *db = openDB();
        exec(db, "UPDATE people SET lastVerified = 2015");
        NSArray<Person *> *people = loadPeople(db);
        if (people.count == 0) {
            fprintf(stderr, "verify: run ./verify create first\n");
            return 1;
        }

        double t0 = now();
        int stamped = 0;
        if (!strcmp(mode, "sql")) {
            exec(db, "UPDATE people SET lastVerified = 2026");
            stamped = sqlite3_changes(db);
        } else if (!strcmp(mode, "linear")) {
            exec(db, "BEGIN");
            sqlite3_stmt *st;
            sqlite3_prepare_v2(db, "UPDATE people SET lastVerified = 2026 WHERE uniqueid = ?", -1, &st, NULL);
            for (Person *p in people) {
                if (!verify(p)) continue;
                sqlite3_bind_int(st, 1, p.uniqueid);
                sqlite3_step(st);
                sqlite3_reset(st);
                stamped++;
            }
            sqlite3_finalize(st);
            exec(db, "COMMIT");
        } else {
            Chan<Person *> *results = chan();
            Chan<NSNumber *> *done = chan();
            go(writer((int)people.count, results, done));
            for (Person *p in people)
                go(verifier(p, results));
            stamped = [done receive].intValue;
        }
        double t = now() - t0;

        printf("%-6s  %4d stamped 2026, %4d left at 2015, %8.3f s\n", mode, countWhere(db, "lastVerified = 2026"),
               countWhere(db, "lastVerified = 2015"), t);
        if (stamped != countWhere(db, "lastVerified = 2026")) {
            fprintf(stderr, "verify: stamped %d but the database says otherwise\n", stamped);
            return 1;
        }
        sqlite3_close(db);
    }
    return 0;
}
