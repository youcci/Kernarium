// SPDX-License-Identifier: Apache-2.0

#define LOG_TAG "andarium.gnss"

#include "location_protocol.hpp"
#include <aidl/android/hardware/gnss/BnGnss.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <host_link.hpp>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <mutex>

namespace {
using namespace aidl::android::hardware::gnss;
using ndk::ScopedAStatus;
using Clock = std::chrono::steady_clock;

ScopedAStatus unsupported() { return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION); }

// The host's location service as Android's GNSS HAL. While the framework has
// the HAL started, the host locates and every fix it sends becomes a location;
// the HAL reports no satellites, measurements or NMEA and offers no extension,
// which the framework takes as a receiver without them. The framework's
// interval is kept here, by dropping the fixes that come sooner.
class Gnss final : public BnGnss {
public:
    ScopedAStatus setCallback(const std::shared_ptr<IGnssCallback>& callback) override {
        if (!callback) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        {
            std::lock_guard lock(mutex_);
            callback_ = callback;
            // A framework that set its callback again has no session running.
            active_ = false;
            tell();
        }
        callback->gnssSetCapabilitiesCb(IGnssCallback::CAPABILITY_SCHEDULING);
        return ScopedAStatus::ok();
    }
    ScopedAStatus close() override {
        std::lock_guard lock(mutex_);
        callback_ = nullptr;
        active_ = false;
        tell();
        return ScopedAStatus::ok();
    }
    ScopedAStatus start() override { return run(true); }
    ScopedAStatus stop() override { return run(false); }
    ScopedAStatus setPositionMode(const PositionModeOptions& options) override {
        std::lock_guard lock(mutex_);
        interval_ = std::chrono::milliseconds(std::max(0, options.minIntervalMs));
        next_ = {};
        return ScopedAStatus::ok();
    }
    // The host's service keeps its own time, position and aiding data.
    ScopedAStatus injectTime(int64_t, int64_t, int32_t) override { return ScopedAStatus::ok(); }
    ScopedAStatus injectLocation(const GnssLocation&) override { return ScopedAStatus::ok(); }
    ScopedAStatus injectBestLocation(const GnssLocation&) override { return ScopedAStatus::ok(); }
    ScopedAStatus deleteAidingData(GnssAidingData) override { return ScopedAStatus::ok(); }
    // There is no satellite status or NMEA to start.
    ScopedAStatus startSvStatus() override { return ScopedAStatus::ok(); }
    ScopedAStatus stopSvStatus() override { return ScopedAStatus::ok(); }
    ScopedAStatus startNmea() override { return ScopedAStatus::ok(); }
    ScopedAStatus stopNmea() override { return ScopedAStatus::ok(); }
    ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>*) override { return unsupported(); }
    ScopedAStatus getExtensionGnssConfiguration(std::shared_ptr<IGnssConfiguration>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssMeasurement(
            std::shared_ptr<IGnssMeasurementInterface>*) override { return unsupported(); }
    ScopedAStatus getExtensionGnssPowerIndication(std::shared_ptr<IGnssPowerIndication>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssBatching(std::shared_ptr<IGnssBatching>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssGeofence(std::shared_ptr<IGnssGeofence>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssNavigationMessage(
            std::shared_ptr<IGnssNavigationMessageInterface>*) override { return unsupported(); }
    ScopedAStatus getExtensionAGnss(std::shared_ptr<IAGnss>*) override { return unsupported(); }
    ScopedAStatus getExtensionAGnssRil(std::shared_ptr<IAGnssRil>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssDebug(std::shared_ptr<IGnssDebug>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssVisibilityControl(
            std::shared_ptr<visibility_control::IGnssVisibilityControl>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssAntennaInfo(std::shared_ptr<IGnssAntennaInfo>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionMeasurementCorrections(
            std::shared_ptr<measurement_corrections::IMeasurementCorrectionsInterface>*) override {
        return unsupported();
    }
    ScopedAStatus getExtensionGnssAssistanceInterface(
            std::shared_ptr<gnss_assistance::IGnssAssistanceInterface>*) override {
        return unsupported();
    }

private:
    ScopedAStatus run(bool active) {
        std::shared_ptr<IGnssCallback> callback;
        {
            std::lock_guard lock(mutex_);
            const bool changed = active_ != active;
            active_ = active;
            next_ = {};
            if (changed) tell();
            callback = callback_;
        }
        if (callback) {
            callback->gnssStatusCb(active ? IGnssCallback::GnssStatusValue::SESSION_BEGIN
                                          : IGnssCallback::GnssStatusValue::SESSION_END);
        }
        return ScopedAStatus::ok();
    }
    // Tells the host whether the framework wants fixes, on the connection it
    // made. Called with mutex_ held.
    void tell() { link_.send(andarium::location::encode_demand(active_)); }
    void attached() {
        std::lock_guard lock(mutex_);
        tell();
    }
    bool received(andarium::HostLink::Frame frame) {
        const auto fix = andarium::location::decode(frame);
        if (!fix) return false;
        std::shared_ptr<IGnssCallback> callback;
        {
            std::lock_guard lock(mutex_);
            if (!active_ || !callback_) return true;
            const auto now = Clock::now();
            // Keep a reporting deadline, with the slack the host's own timing
            // needs, so a fix that is a little early is not dropped.
            if (now + interval_ / 10 < next_) return true;
            next_ = now + interval_;
            callback = callback_;
        }
        GnssLocation location{};
        // The protocol's flags are GnssLocation's, and a value whose flag is
        // clear is zero.
        location.gnssLocationFlags = int32_t(fix->flags);
        location.latitudeDegrees = fix->values[0];
        location.longitudeDegrees = fix->values[1];
        location.altitudeMeters = fix->values[2];
        location.speedMetersPerSec = fix->values[3];
        location.bearingDegrees = fix->values[4];
        location.horizontalAccuracyMeters = fix->values[5];
        location.verticalAccuracyMeters = fix->values[6];
        location.speedAccuracyMetersPerSecond = fix->values[7];
        location.bearingAccuracyDegrees = fix->values[8];
        location.timestampMillis = fix->time_ms;
        // The framework stamps the fix with its own elapsed time at receipt.
        callback->gnssLocationCb(location);
        return true;
    }
    std::mutex mutex_;
    std::shared_ptr<IGnssCallback> callback_;
    bool active_ = false;
    Clock::duration interval_{};
    Clock::time_point next_{};
    andarium::HostLink link_{"Andarium location", andarium::location::port,
                             andarium::location::fix_size, [this] { attached(); },
                             [this](andarium::HostLink::Frame frame) { return received(frame); }};
};
} // namespace

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(1);
    ABinderProcess_startThreadPool();
    const auto gnss = ndk::SharedRefBase::make<Gnss>();
    const auto name = std::string(Gnss::descriptor) + "/default";
    if (AServiceManager_addService(gnss->asBinder().get(), name.c_str()) != STATUS_OK) {
        ALOGE("cannot register %s", name.c_str());
        return EXIT_FAILURE;
    }
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;
}
