// SPDX-License-Identifier: Apache-2.0

#define LOG_TAG "andarium.vibrator"

#include "vibration_protocol.hpp"
#include <aidl/android/hardware/vibrator/BnVibrator.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <host_link.hpp>
#include <chrono>
#include <cstdlib>
#include <mutex>

namespace {
using namespace aidl::android::hardware::vibrator;
using ndk::ScopedAStatus;
using Clock = std::chrono::steady_clock;

ScopedAStatus unsupported() { return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION); }

// The host's haptic engine as Android's vibrator: on for a time, off, and an
// amplitude. The host plays what the frames say; without a host connection, or
// on a host with no haptics, the calls succeed and nothing vibrates. The
// framework times each vibration itself (no completion callback is offered)
// and replaces every effect and primitive by its own on/off fallback.
class Vibrator final : public BnVibrator {
public:
    ScopedAStatus getCapabilities(int32_t* capabilities) override {
        *capabilities = CAP_AMPLITUDE_CONTROL;
        return ScopedAStatus::ok();
    }
    ScopedAStatus off() override {
        std::lock_guard lock(mutex_);
        until_ = {};
        tell(0);
        return ScopedAStatus::ok();
    }
    ScopedAStatus on(int32_t timeoutMs, const std::shared_ptr<IVibratorCallback>&) override {
        if (timeoutMs <= 0) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        std::lock_guard lock(mutex_);
        until_ = Clock::now() + std::chrono::milliseconds(timeoutMs);
        tell(timeoutMs);
        return ScopedAStatus::ok();
    }
    ScopedAStatus setAmplitude(float amplitude) override {
        if (!(amplitude > 0 && amplitude <= 1)) {
            return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }
        std::lock_guard lock(mutex_);
        amplitude_ = amplitude;
        // The framework turns the vibrator on and then sets the amplitude of
        // what it plays, so the rest of that vibration takes the new one.
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                until_ - Clock::now()).count();
        if (left > 0) tell(uint32_t(left));
        return ScopedAStatus::ok();
    }
    ScopedAStatus getSupportedEffects(std::vector<Effect>* effects) override {
        effects->clear();
        return ScopedAStatus::ok();
    }
    ScopedAStatus perform(Effect, EffectStrength, const std::shared_ptr<IVibratorCallback>&,
                          int32_t*) override { return unsupported(); }
    ScopedAStatus performVendorEffect(const VendorEffect&,
                                      const std::shared_ptr<IVibratorCallback>&) override {
        return unsupported();
    }
    ScopedAStatus setExternalControl(bool) override { return unsupported(); }
    ScopedAStatus getCompositionDelayMax(int32_t*) override { return unsupported(); }
    ScopedAStatus getCompositionSizeMax(int32_t*) override { return unsupported(); }
    ScopedAStatus getSupportedPrimitives(std::vector<CompositePrimitive>*) override {
        return unsupported();
    }
    ScopedAStatus getPrimitiveDuration(CompositePrimitive, int32_t*) override {
        return unsupported();
    }
    ScopedAStatus compose(const std::vector<CompositeEffect>&,
                          const std::shared_ptr<IVibratorCallback>&) override {
        return unsupported();
    }
    ScopedAStatus getSupportedAlwaysOnEffects(std::vector<Effect>*) override {
        return unsupported();
    }
    ScopedAStatus alwaysOnEnable(int32_t, Effect, EffectStrength) override { return unsupported(); }
    ScopedAStatus alwaysOnDisable(int32_t) override { return unsupported(); }
    ScopedAStatus getResonantFrequency(float*) override { return unsupported(); }
    ScopedAStatus getQFactor(float*) override { return unsupported(); }
    ScopedAStatus getFrequencyResolution(float*) override { return unsupported(); }
    ScopedAStatus getFrequencyMinimum(float*) override { return unsupported(); }
    ScopedAStatus getBandwidthAmplitudeMap(std::vector<float>*) override { return unsupported(); }
    ScopedAStatus getPwlePrimitiveDurationMax(int32_t*) override { return unsupported(); }
    ScopedAStatus getPwleCompositionSizeMax(int32_t*) override { return unsupported(); }
    ScopedAStatus getSupportedBraking(std::vector<Braking>*) override { return unsupported(); }
    ScopedAStatus composePwle(const std::vector<PrimitivePwle>&,
                              const std::shared_ptr<IVibratorCallback>&) override {
        return unsupported();
    }
    ScopedAStatus getFrequencyToOutputAccelerationMap(
            std::vector<FrequencyAccelerationMapEntry>*) override { return unsupported(); }
    ScopedAStatus getPwleV2PrimitiveDurationMaxMillis(int32_t*) override { return unsupported(); }
    ScopedAStatus getPwleV2PrimitiveDurationMinMillis(int32_t*) override { return unsupported(); }
    ScopedAStatus getPwleV2CompositionSizeMax(int32_t*) override { return unsupported(); }
    ScopedAStatus composePwleV2(const CompositePwleV2&,
                                const std::shared_ptr<IVibratorCallback>&) override {
        return unsupported();
    }

private:
    // Called with mutex_ held.
    void tell(uint32_t duration_ms) {
        link_.send(andarium::vibration::encode(duration_ms, amplitude_));
    }
    std::mutex mutex_;
    float amplitude_ = 1;
    Clock::time_point until_{};
    // A host that connects in the middle of a vibration plays the next one.
    andarium::HostLink link_{"Andarium vibrator", andarium::vibration::port, 0, [] {},
                             [](andarium::HostLink::Frame) { return false; }};
};
} // namespace

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(0);
    const auto vibrator = ndk::SharedRefBase::make<Vibrator>();
    const auto name = std::string(Vibrator::descriptor) + "/default";
    if (AServiceManager_addService(vibrator->asBinder().get(), name.c_str()) != STATUS_OK) {
        ALOGE("cannot register %s", name.c_str());
        return EXIT_FAILURE;
    }
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;
}
