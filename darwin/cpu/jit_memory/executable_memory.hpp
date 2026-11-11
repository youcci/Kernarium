// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <cstddef>

/* The only first-party owner of executable memory. It maps JIT memory, opens
 * and closes the calling thread's write window over it, and publishes the
 * instructions written there. JIT engines reach executable memory only
 * through these calls; the gadget engines and shared CPU code never link
 * them. allocate, release and set_writable have the shapes of FEXCore's
 * executable-memory hooks.
 */
namespace uml::cpu::jit_memory {

/* Whether this process can run JIT code: a publication route exists and a JIT
 * mapping succeeds. On macOS the answer is probed once per process, and a
 * process that can claims the window allocate serves from then, before other
 * mappings fill the range near this image. On an iPhone it holds once
 * claim_from_debugger has succeeded.
 */
[[nodiscard]] bool available() noexcept;

#ifndef UML_APP_STORE_RUNTIME
/* The iPhone's route to JIT memory, which an App Store runtime does not have;
 * false on every other product. Call it before the application asks StikDebug
 * to attach. It waits, within a bound, for that debugger, has it prepare the
 * one window allocate serves from, and detaches it; the answer is whether the
 * window exists. A debugger that is attached already is not used, and later
 * calls only report.
 */
[[nodiscard]] bool claim_from_debugger() noexcept;
#endif

/* The most JIT memory this process can hold at once, or zero where the host
 * sets no bound. A JIT sizes its caches to fit.
 */
[[nodiscard]] std::size_t capacity() noexcept;

/* Returns size bytes of JIT memory to write and run, or nullptr. A thread
 * writes it only inside its write window and only through writable(). On
 * macOS the memory comes from one window near this image, because Apple cores
 * predict an indirect branch's target cheaply only near the branch; memory
 * released and served again may still hold its old bytes.
 */
[[nodiscard]] void *allocate(std::size_t size) noexcept;

/* The address that writes the JIT memory which runs at code: code itself on
 * macOS, and the window's second, writable mapping on an iPhone, where the
 * mapping that runs is never writable.
 */
[[nodiscard]] void *writable(void *code) noexcept;

/* The calls below end in the C library, which the compiler cannot prove
 * nothrow. They are not noexcept, so none compiles to a frame with its own
 * terminate handler.
 */

/* Returns memory allocate served; size is the size it was asked for. */
void release(void *mapping, std::size_t size);

/* Opens (true) or closes (false) the calling thread's write window over every
 * JIT mapping. While the window is open, the thread cannot execute JIT code.
 */
void set_writable(bool writable);

/* Makes size bytes of instructions written at code visible to instruction
 * fetch. Call it after closing the write window.
 */
void invalidate_instruction_cache(void *code, std::size_t size);

/* Reserves size bytes of ordinary read-write data between two inaccessible
 * guard regions, each one host page long, or returns nullptr. A JIT keeps
 * data its generated code addresses unchecked there, so an engine fault that
 * runs off either end stops at a guard instead of corrupting the heap. size
 * must be a multiple of the host page size.
 */
[[nodiscard]] void *reserve_guarded(std::size_t size) noexcept;

/* Releases a reservation reserve_guarded made of size bytes. */
void release_guarded(void *data, std::size_t size);

} // namespace uml::cpu::jit_memory
