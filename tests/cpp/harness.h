/*
** harness.h
**
** Registration and reporting for the host-side C++ tests. A test
** file writes cases and nothing else. The TEST macro registers each
** one, so no list needs an edit when a file gains a case. Inside a
** case, CHECK takes a condition and CHECK_EQ takes an expected value
** and an actual one.
**
** Output uses the same "[TEST] " grammar as the in-engine Ruby
** suites, so one reader handles both:
**
**   [TEST] SUITE cpp
**   [TEST] ok patcher_replaces_a_literal
**   [TEST] FAIL patcher_replaces_a_literal
**   [TEST] DONE passed=<n> failed=<n>
**
** A failed CHECK prints its file, its line, and what it saw on the
** line above the FAIL.
**
** A case that runs no check at all fails. An empty case is a hole in
** the coverage, not a pass.
*/

#ifndef TESTS_CPP_HARNESS_H
#define TESTS_CPP_HARNESS_H

#include <sstream>
#include <string>

namespace enginetest {

void registerCase(const char *name, void (*run)());

/* Counts one check against the running case. The runner fails a case
 * that never calls this, because a case that asserts nothing cannot
 * tell a working engine from a broken one. */
void countCheck();

/* Records a failure against the running case. Every CHECK in a case
 * runs, so one call site does not hide the ones after it. */
void fail(const char *file, int line, const std::string &detail);

template <typename T>
std::string show(const T &value)
{
    std::ostringstream out;
    out << std::boolalpha << value;
    return out.str();
}

struct Registrar
{
    Registrar(const char *name, void (*run)()) { registerCase(name, run); }
};

} // namespace enginetest

#define TEST(name)                                                       \
    static void name();                                                  \
    static const enginetest::Registrar name##_registrar(#name, name);    \
    static void name()

#define CHECK(condition)                                                 \
    do {                                                                 \
        enginetest::countCheck();                                        \
        if (!(condition))                                                \
            enginetest::fail(__FILE__, __LINE__, #condition);            \
    } while (0)

#define CHECK_EQ(expected, actual)                                       \
    do {                                                                 \
        enginetest::countCheck();                                        \
        const auto &e_ = (expected);                                     \
        const auto &a_ = (actual);                                       \
        if (!(e_ == a_))                                                 \
            enginetest::fail(__FILE__, __LINE__,                         \
                             std::string(#actual) + ": expected " +      \
                                 enginetest::show(e_) + ", got " +       \
                                 enginetest::show(a_));                  \
    } while (0)

#endif /* TESTS_CPP_HARNESS_H */
