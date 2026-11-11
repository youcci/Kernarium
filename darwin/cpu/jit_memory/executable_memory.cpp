// SPDX-License-Identifier: GPL-2.0-or-later
#include "executable_memory.hpp"

#include <sys/mman.h>

#include <TargetConditionals.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

#include <array>
#include <cstddef>
#include <cstdint>

#if defined(__APPLE__) && TARGET_OS_IPHONE && !defined(UML_APP_STORE_RUNTIME)
/* The code-signing status call of the C library, which no SDK header declares. */
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr,
	size_t usersize);
#endif

namespace uml::cpu::jit_memory {
namespace {

/* How this process comes by memory it can write code into and run.
 *
 * toggle: macOS maps MAP_JIT memory and switches the calling thread between
 * writing and running it with pthread_jit_write_protect_np.
 *
 * debugger: an iPhone grants an application no JIT memory of its own, but a
 * debugger can make a region of a debugged process executable. A development
 * runtime has the debugger its application asked for prepare one window, runs
 * code through that mapping and writes it through a second, writable mapping
 * of the same pages (claim_from_debugger). An App Store runtime holds none of
 * it.
 *
 * none: every other product. The Simulator is deliberately held to this answer
 * even though it runs on macOS and could reach the toggle dynamically: letting
 * it translate through a path production devices cannot use would make it
 * unrepresentative of the product it exists to stand in for.
 */
enum class Route { none, toggle, debugger };

#if defined(__APPLE__) && defined(__aarch64__) && defined(MAP_JIT) && \
	!defined(__IPHONE_OS_VERSION_MAX_ALLOWED)
constexpr auto route = Route::toggle;

void jit_write_protect(int enable)
{
	pthread_jit_write_protect_np(enable);
}
#else
#if defined(__APPLE__) && defined(__aarch64__) && TARGET_OS_IPHONE && \
	!TARGET_OS_SIMULATOR && !defined(UML_APP_STORE_RUNTIME)
#define UML_JIT_MEMORY_FROM_DEBUGGER 1
constexpr auto route = Route::debugger;
#else
constexpr auto route = Route::none;
#endif

constexpr void jit_write_protect(int) {}
#endif

#ifdef UML_JIT_MEMORY_FROM_DEBUGGER
/* The window a debugger is asked for: the size it was shown to prepare on an
 * iPhone. The debugger touches every page of it, so the whole window counts
 * as resident from the start, and none can be added once the debugger has
 * left.
 * The launch's memory plan counts it and no more, which holds while a JIT
 * held to it keeps less outside its arenas than the gadget cache's least
 * budget (arm64-jit-cache-geometry).
 * shortcut: one size for every guest; measure Android's arena use on the
 * phone before growing it. */
constexpr std::size_t debugger_window_bytes = 256U * 1024U * 1024U;
/* How long the debugger the application asked for may take to attach. */
constexpr unsigned debugger_wait_seconds = 120;

[[nodiscard]] bool debugged() noexcept
{
	constexpr unsigned status = 0; /* CS_OPS_STATUS */
	constexpr std::uint32_t debugged_flag = 0x10000000U; /* CS_DEBUGGED */
	std::uint32_t flags = 0;
	return csops(getpid(), status, &flags, sizeof flags) == 0 &&
		(flags & debugged_flag) != 0;
}

/* StikDebug's breakpoint protocol: the debugger's script reads the command in
 * x16, steps over the breakpoint and answers in x0. Without that debugger the
 * breakpoint ends the process, so neither runs before debugged() holds. */

/* Has the debugger map size executable bytes; the mapping, or nullptr. */
[[gnu::naked, gnu::noinline]] void *debugger_prepare(void *, std::size_t)
{
	__asm__("mov x16, #1\n"
		"brk #0xf00d\n"
		"ret\n");
}

[[gnu::naked, gnu::noinline]] void debugger_detach()
{
	__asm__("mov x16, #0\n"
		"brk #0xf00d\n"
		"ret\n");
}

/* A breakpoint no debugger answers raises SIGTRAP, which ends the process: a
 * debugger that attached may be gone again, or run no script. While the claim
 * makes its two calls this handler answers in the debugger's place: it steps
 * over the breakpoint with a null answer, so the claim fails and the process
 * runs on. Any other trap takes the default action. */
void answer_unanswered_breakpoint(int, siginfo_t *, void *context)
{
	constexpr std::uint32_t breakpoint = 0xd43e01a0U; /* brk #0xf00d */
	auto &state = static_cast<ucontext_t *>(context)->uc_mcontext->__ss;
	if (*reinterpret_cast<const std::uint32_t *>(state.__pc) != breakpoint) {
		(void)signal(SIGTRAP, SIG_DFL);
		return;
	}
	state.__x[0] = 0;
	state.__pc += 4;
}

/* A writable mapping of the size bytes at code, or nullptr. */
[[nodiscard]] void *writable_alias(void *code, std::size_t size) noexcept
{
	vm_address_t alias = 0;
	vm_prot_t current = 0;
	vm_prot_t maximum = 0;
	if (vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE,
		    mach_task_self(), reinterpret_cast<vm_address_t>(code),
		    FALSE, &current, &maximum, VM_INHERIT_NONE) != KERN_SUCCESS)
		return nullptr;
	if (mprotect(reinterpret_cast<void *>(alias), size,
		    PROT_READ | PROT_WRITE) != 0) {
		(void)vm_deallocate(mach_task_self(), alias, size);
		return nullptr;
	}
	return reinterpret_cast<void *>(alias);
}
#endif

/* Where JIT code lives.
 *
 * An Apple core predicts an indirect branch's target cheaply only when the
 * target lies near the branch. On an M1 Ultra a call through a register and
 * its return cost about 0.7 ns when caller and callee share an aligned
 * 512 MiB block, 1.9 ns when they share an aligned 4 GiB block, and 5 ns or
 * more when they do not. Generated code calls into this image -- FEXCore
 * reaches its x87 softfloat fallbacks that way for every x87 operation -- and
 * jumps between its own allocations, so where a mapping lands decides how fast
 * the code in it runs.
 *
 * The kernel places a mapping at the lowest free range. The 2 GiB between this
 * image and the shared cache fill with the JIT's own data, so a code buffer
 * mapped later in a run landed some 400 GiB away, and the guest process it
 * served ran x87 code a third slower than its neighbours.
 *
 * So the process claims one window, the largest, up to 1.5 GiB in 64 MiB
 * steps, whose lowest free range at or above this image's 512 MiB block lies
 * in its 4 GiB block, and serves every allocation from it, lowest address
 * first. It claims the window when it first asks whether it can run JIT
 * code, which it does when it selects a JIT engine, before its kernel boots:
 * by the first allocation the range is already scattered with small
 * mappings, and the JIT's data reservations claim the rest of it as soon as
 * the first contexts exist. FEXCore keeps a 16 MiB code buffer for each of
 * the eight address spaces each vCPU caches, so ten vCPUs keep 80 of them.
 *
 * MAP_JIT cannot map over an existing range, and a hole in a live window
 * would be the kernel's first choice for an unrelated mapping, so a release
 * keeps the pages mapped and marks them reusable; memory served again may
 * still hold what it held before. When the window is full, or cannot be
 * placed, a mapping goes wherever the kernel puts it.
 *
 * On the debugger route the window is the one region the debugger prepared,
 * wherever it put it. Nothing can be mapped beside it later, and its pages
 * stay as the debugger left them, so a release only frees the range.
 */
class Window final {
public:
	void claim() noexcept
	{
		os_unfair_lock_lock(&lock_);
		claim_locked();
		os_unfair_lock_unlock(&lock_);
	}

	[[nodiscard]] void *allocate(std::size_t size) noexcept
	{
		if (size == 0 || size > max_bytes)
			return nullptr;
		const auto count = granules_for(size);
		os_unfair_lock_lock(&lock_);
		claim_locked();
		const auto first = find(count);
		if (first != none)
			mark(first, count, true);
		os_unfair_lock_unlock(&lock_);
		if (first == none)
			return nullptr;
		void *mapping = base_ + first * granule;
		/* A released range is reusable: the kernel may discard its pages
		 * until it is claimed back. */
		if constexpr (route == Route::toggle)
			(void)madvise(mapping, count * granule, MADV_FREE_REUSE);
		return mapping;
	}

	/* Whether mapping came from the window; if so its pages return to it. */
	[[nodiscard]] bool release(void *mapping, std::size_t size) noexcept
	{
		os_unfair_lock_lock(&lock_);
		std::byte *const base = base_;
		const std::size_t granules = granules_;
		os_unfair_lock_unlock(&lock_);
		auto *const bytes = static_cast<std::byte *>(mapping);
		if (base == nullptr || bytes < base ||
		    bytes >= base + granules * granule)
			return false;
		const auto first =
			static_cast<std::size_t>(bytes - base) / granule;
		const auto count = granules_for(size);
		if (count > granules - first)
			return true;
		/* Marked reusable before it is free, so no later claim can
		 * race the advice. */
		if constexpr (route == Route::toggle)
			(void)madvise(mapping, count * granule,
				MADV_FREE_REUSABLE);
		os_unfair_lock_lock(&lock_);
		mark(first, count, false);
		os_unfair_lock_unlock(&lock_);
		return true;
	}

	/* The window's size, zero while there is none. */
	[[nodiscard]] std::size_t bytes() noexcept
	{
		os_unfair_lock_lock(&lock_);
		const auto bytes = granules_ * granule;
		os_unfair_lock_unlock(&lock_);
		return bytes;
	}

#ifdef UML_JIT_MEMORY_FROM_DEBUGGER
	/* The address that writes the window's byte at code. A caller holds
	 * code only after the window exists, so this reads without the lock. */
	[[nodiscard]] void *writable(void *code) const noexcept
	{
		return static_cast<std::byte *>(code) + alias_offset_;
	}

	[[nodiscard]] bool claim_from_debugger() noexcept
	{
		os_unfair_lock_lock(&lock_);
		const bool first = !claimed_;
		claimed_ = true;
		os_unfair_lock_unlock(&lock_);
		/* A debugger that is here before the application asked for one
		 * is somebody else's, and would stop at the breakpoint. */
		if (!first || debugged())
			return bytes() != 0;
		for (unsigned polls = 0; !debugged(); ++polls) {
			if (polls == debugger_wait_seconds * 4U)
				return false;
			(void)usleep(250000);
		}
		struct sigaction answer{};
		struct sigaction previous{};
		answer.sa_sigaction = &answer_unanswered_breakpoint;
		answer.sa_flags = SA_SIGINFO;
		(void)sigemptyset(&answer.sa_mask);
		(void)sigaction(SIGTRAP, &answer, &previous);
		/* The debugger leaves at once: while it is attached every
		 * signal of the process waits for it to answer. */
		void *const code =
			debugger_prepare(nullptr, debugger_window_bytes);
		void *const alias = code == nullptr ? nullptr :
			writable_alias(code, debugger_window_bytes);
		debugger_detach();
		(void)sigaction(SIGTRAP, &previous, nullptr);
		if (alias == nullptr)
			return false;
		os_unfair_lock_lock(&lock_);
		base_ = static_cast<std::byte *>(code);
		granules_ = debugger_window_bytes / granule;
		alias_offset_ = static_cast<std::byte *>(alias) - base_;
		os_unfair_lock_unlock(&lock_);
		return true;
	}
#endif

private:
	/* The host page on every Apple arm64 product. */
	static constexpr std::size_t granule = 16U * 1024U;
	static constexpr std::size_t step_bytes = 64U * 1024U * 1024U;
	static constexpr std::size_t max_bytes = 24U * step_bytes;
	static constexpr std::uintptr_t prediction_block = std::uintptr_t{1} << 29U;
	static constexpr std::uintptr_t near_block = std::uintptr_t{1} << 32U;
	static constexpr std::size_t none = ~std::size_t{0};

	[[nodiscard]] static constexpr std::size_t granules_for(
		std::size_t size) noexcept
	{
		return (size + granule - 1U) / granule;
	}

	void claim_locked() noexcept
	{
		if (claimed_ || route != Route::toggle)
			return;
		claimed_ = true;
		if (static_cast<std::size_t>(getpagesize()) > granule)
			return;
		/* Any function of this image locates it. */
		const auto image = reinterpret_cast<std::uintptr_t>(
			&::uml::cpu::jit_memory::allocate);
		const auto hint = image & ~(prediction_block - 1U);
		const auto block = image & ~(near_block - 1U);
		for (auto bytes = max_bytes; bytes != 0; bytes -= step_bytes) {
			void *mapping = mmap(reinterpret_cast<void *>(hint), bytes,
				PROT_READ | PROT_WRITE | PROT_EXEC,
				MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
			if (mapping == MAP_FAILED)
				continue;
			const auto start = reinterpret_cast<std::uintptr_t>(mapping);
			if (start >= block && start - block <= near_block - bytes) {
				base_ = static_cast<std::byte *>(mapping);
				granules_ = bytes / granule;
				return;
			}
			(void)munmap(mapping, bytes);
		}
	}

	[[nodiscard]] std::size_t find(std::size_t count) const noexcept
	{
		std::size_t run = 0;
		for (std::size_t i = 0; i < granules_;) {
			const auto word = used_[i / 64U];
			if (i % 64U == 0 && word == ~std::uint64_t{0}) {
				run = 0;
				i += 64U;
				continue;
			}
			if (((word >> (i % 64U)) & 1U) != 0)
				run = 0;
			else if (++run == count)
				return i + 1U - count;
			++i;
		}
		return none;
	}

	void mark(std::size_t first, std::size_t count, bool used) noexcept
	{
		for (auto i = first; i < first + count; ++i) {
			const auto bit = std::uint64_t{1} << (i % 64U);
			if (used)
				used_[i / 64U] |= bit;
			else
				used_[i / 64U] &= ~bit;
		}
	}

	os_unfair_lock lock_ = OS_UNFAIR_LOCK_INIT;
	bool claimed_{};
	std::byte *base_{};
	std::size_t granules_{};
#ifdef UML_JIT_MEMORY_FROM_DEBUGGER
	std::ptrdiff_t alias_offset_{};
#endif
	std::array<std::uint64_t, max_bytes / granule / 64U> used_{};
};

constinit Window window;

} // namespace

bool available() noexcept
{
	/* The debugger's window appears while the process runs, so this route
	 * is asked each time. */
	if constexpr (route == Route::debugger)
		return window.bytes() != 0;
	static const bool supported = [] {
#if defined(__APPLE__) && defined(__aarch64__) && defined(MAP_JIT)
		/* A successful MAP_JIT mapping is necessary but not sufficient:
		 * without a W^X toggle the first store into it faults. Requiring
		 * the publication route keeps this from promising an engine that
		 * would abort on its first translated block.
		 */
		if (route != Route::toggle)
			return false;
		void *mapping = mmap(nullptr, 16U * 1024U,
			PROT_READ | PROT_WRITE | PROT_EXEC,
			MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
		if (mapping == MAP_FAILED)
			return false;
		(void)munmap(mapping, 16U * 1024U);
		window.claim();
		return true;
#else
		return false;
#endif
	}();
	return supported;
}

#ifndef UML_APP_STORE_RUNTIME
bool claim_from_debugger() noexcept
{
#ifdef UML_JIT_MEMORY_FROM_DEBUGGER
	return window.claim_from_debugger();
#else
	return false;
#endif
}
#endif

std::size_t capacity() noexcept
{
	return route == Route::debugger ? window.bytes() : 0;
}

void *allocate(std::size_t size) noexcept
{
	if constexpr (route != Route::none) {
		if (void *mapping = window.allocate(size); mapping != nullptr)
			return mapping;
	}
	if constexpr (route == Route::debugger)
		return nullptr;
	void *mapping = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC,
		MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
	return mapping == MAP_FAILED ? nullptr : mapping;
}

void release(void *mapping, std::size_t size)
{
	if constexpr (route != Route::none) {
		if (window.release(mapping, size))
			return;
	}
	(void)munmap(mapping, size);
}

void *writable(void *code) noexcept
{
#ifdef UML_JIT_MEMORY_FROM_DEBUGGER
	return window.writable(code);
#else
	return code;
#endif
}

void set_writable(bool writable)
{
	jit_write_protect(writable ? 0 : 1);
}

void invalidate_instruction_cache(void *code, std::size_t size)
{
	sys_icache_invalidate(code, size);
}

void *reserve_guarded(std::size_t size) noexcept
{
	const auto guard = static_cast<std::size_t>(getpagesize());
	if (size == 0 || size % guard != 0 || size > SIZE_MAX - 2 * guard)
		return nullptr;
	void *mapping = mmap(nullptr, size + 2 * guard, PROT_NONE,
		MAP_PRIVATE | MAP_ANON, -1, 0);
	if (mapping == MAP_FAILED)
		return nullptr;
	auto *data = static_cast<std::byte *>(mapping) + guard;
	if (mprotect(data, size, PROT_READ | PROT_WRITE) != 0) {
		(void)munmap(mapping, size + 2 * guard);
		return nullptr;
	}
	return data;
}

void release_guarded(void *data, std::size_t size)
{
	const auto guard = static_cast<std::size_t>(getpagesize());
	(void)munmap(static_cast<std::byte *>(data) - guard, size + 2 * guard);
}

} // namespace uml::cpu::jit_memory
