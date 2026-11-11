/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include "cpu/engine.hpp"

#include <cstddef>
#include <memory>

namespace uml::cpu::arm64::detail {

[[nodiscard]] std::unique_ptr<CpuEngine> make_gadget_engine(
	EngineConfiguration configuration);
[[nodiscard]] std::unique_ptr<CpuEngine> make_jit_engine(
	EngineConfiguration configuration);
[[nodiscard]] bool native_jit_engine_available() noexcept;
[[nodiscard]] std::size_t jit_memory_bound() noexcept;
#ifndef UML_APP_STORE_RUNTIME
[[nodiscard]] bool claim_debugger_jit_memory() noexcept;
#endif

} // namespace uml::cpu::arm64::detail
