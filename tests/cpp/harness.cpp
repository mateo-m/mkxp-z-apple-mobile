/*
** harness.cpp
**
** The registry, the runner, and main. See harness.h.
*/

#include "harness.h"

#include <cstdio>
#include <exception>
#include <string>
#include <vector>

namespace {

struct Case
{
    const char *name;
    void (*run)();
};

/* A function-local static, not a file-scope one. Cases register from
 * static initialisers in other translation units, and the order of
 * those against a file-scope container is not defined. */
std::vector<Case> &cases()
{
    static std::vector<Case> registry;
    return registry;
}

int failedChecks = 0;
int ranChecks = 0;

void emit(const std::string &line)
{
    std::printf("[TEST] %s\n", line.c_str());
    std::fflush(stdout);
}

} // namespace

namespace enginetest {

void registerCase(const char *name, void (*run)())
{
    cases().push_back(Case{name, run});
}

void countCheck()
{
    ranChecks++;
}

void fail(const char *file, int line, const std::string &detail)
{
    failedChecks++;
    emit("  " + std::string(file) + ":" + std::to_string(line) + ": " + detail);
}

} // namespace enginetest

int main()
{
    emit("SUITE cpp");

    int passed = 0;
    int failed = 0;

    /* An empty registry means the cases never linked in. Reporting
     * "0 failed" for that would read as a pass. */
    if (cases().empty()) {
        emit("FAIL <registry>");
        emit("  no test case registered");
        emit("DONE passed=0 failed=1");
        return 1;
    }

    for (const Case &test : cases()) {
        failedChecks = 0;
        ranChecks = 0;
        try {
            test.run();
        } catch (const std::exception &e) {
            enginetest::fail("<case>", 0, std::string("threw ") + e.what());
        } catch (...) {
            enginetest::fail("<case>", 0, "threw an unknown exception");
        }

        if (ranChecks == 0)
            enginetest::fail("<case>", 0, "the case ran no check");

        if (failedChecks == 0) {
            passed++;
            emit(std::string("ok ") + test.name);
        } else {
            failed++;
            emit(std::string("FAIL ") + test.name);
        }
    }

    emit("DONE passed=" + std::to_string(passed) + " failed=" +
         std::to_string(failed));
    return failed == 0 ? 0 : 1;
}
