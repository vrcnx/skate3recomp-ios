#include "skate3_fov.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <string_view>

#include <rex/cvar.h>
#include <rex/graphics/native_guest_renderer.h>

namespace {

constexpr double kDefaultFieldOfViewDegrees = 60.0;
constexpr double kFieldOfViewEpsilon = 0.001;
constexpr double kDegreesToRadians = 3.14159265358979323846 / 180.0;

std::atomic<uint32_t> g_projection_fov_override_bits{0};

float FloatFromBits(uint32_t value) {
  union {
    uint32_t u;
    float f;
  } bits{value};
  return bits.f;
}

uint32_t BitsFromFloat(float value) {
  union {
    float f;
    uint32_t u;
  } bits{value};
  return bits.u;
}

}  // namespace

void Skate3UpdateFieldOfViewOverride(double degrees) {
  if (!std::isfinite(degrees) ||
      std::abs(degrees - kDefaultFieldOfViewDegrees) <= kFieldOfViewEpsilon) {
    g_projection_fov_override_bits.store(0, std::memory_order_relaxed);
    return;
  }

  const double clamped_degrees = std::clamp(degrees, 40.0, 120.0);
  const float radians = float(clamped_degrees * kDegreesToRadians);
  if (!std::isfinite(radians) || radians <= 0.0f) {
    g_projection_fov_override_bits.store(0, std::memory_order_relaxed);
    return;
  }

  g_projection_fov_override_bits.store(BitsFromFloat(radians), std::memory_order_relaxed);
}

void Skate3InitializeFieldOfViewOverride() {
  Skate3UpdateFieldOfViewOverride(rex::cvar::Query<double>("skate3_field_of_view"));
  rex::cvar::RegisterChangeCallback(
      "skate3_field_of_view", [](std::string_view, std::string_view value) {
        double degrees = 0.0;
        if (rex::cvar::ParseDouble(value, degrees)) {
          Skate3UpdateFieldOfViewOverride(degrees);
        }
      });
}

float Skate3MaybeOverrideProjectionFovRadians(float native_radians) {
  // Camera-like FOVs only (the routine also builds other projections).
  if (!std::isfinite(native_radians) || native_radians < 0.5f || native_radians > 2.4f) {
    return native_radians;
  }
  const uint32_t override_bits = g_projection_fov_override_bits.load(std::memory_order_relaxed);
  float radians = override_bits ? FloatFromBits(override_bits) : native_radians;

  // Display narrower than 16:9 (a 4:3 iPad filled edge to edge): project a
  // taller view so the game's own culling and shadows cover it; the native
  // renderer crops the sides back by the same factor (WideOutputHorScale),
  // leaving the 16:9 horizontal view with extra height (Vert+). Scaling the
  // half-angle tangent works whichever axis the game's FOV refers to, since
  // the game keeps its 16:9 projection aspect.
  const double display_aspect = rex::graphics::GetNativeGuestOutputWideAspect();
  constexpr double kGameAspect = 16.0 / 9.0;
  if (display_aspect > 0.0 && display_aspect < kGameAspect - 0.01 &&
      rex::graphics::IsNativeGuestOutputActive()) {
    const double widened =
        2.0 * std::atan(std::tan(0.5 * double(radians)) * (kGameAspect / display_aspect));
    radians = float(std::min(widened, 2.9));
  }
  return radians;
}
