// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <cstdint>

namespace nc::base::keycodes {

// Virtual key codes used by NSEvent/CGEvent. Values are stable across macOS
// keyboard layouts; they used to come from Carbon's Events.h.
inline constexpr std::uint16_t kVK_ANSI_A = 0x00;
inline constexpr std::uint16_t kVK_ANSI_S = 0x01;
inline constexpr std::uint16_t kVK_ANSI_D = 0x02;
inline constexpr std::uint16_t kVK_ANSI_F = 0x03;
inline constexpr std::uint16_t kVK_ANSI_H = 0x04;
inline constexpr std::uint16_t kVK_ANSI_G = 0x05;
inline constexpr std::uint16_t kVK_ANSI_Z = 0x06;
inline constexpr std::uint16_t kVK_ANSI_X = 0x07;
inline constexpr std::uint16_t kVK_ANSI_C = 0x08;
inline constexpr std::uint16_t kVK_ANSI_V = 0x09;
inline constexpr std::uint16_t kVK_ANSI_B = 0x0B;
inline constexpr std::uint16_t kVK_ANSI_Q = 0x0C;
inline constexpr std::uint16_t kVK_ANSI_W = 0x0D;
inline constexpr std::uint16_t kVK_ANSI_E = 0x0E;
inline constexpr std::uint16_t kVK_ANSI_R = 0x0F;
inline constexpr std::uint16_t kVK_ANSI_Y = 0x10;
inline constexpr std::uint16_t kVK_ANSI_T = 0x11;
inline constexpr std::uint16_t kVK_ANSI_O = 0x1F;
inline constexpr std::uint16_t kVK_ANSI_U = 0x20;
inline constexpr std::uint16_t kVK_ANSI_I = 0x22;
inline constexpr std::uint16_t kVK_ANSI_P = 0x23;
inline constexpr std::uint16_t kVK_ANSI_L = 0x25;
inline constexpr std::uint16_t kVK_ANSI_J = 0x26;
inline constexpr std::uint16_t kVK_ANSI_K = 0x28;
inline constexpr std::uint16_t kVK_ANSI_N = 0x2D;
inline constexpr std::uint16_t kVK_ANSI_M = 0x2E;
inline constexpr std::uint16_t kVK_Return = 0x24;
inline constexpr std::uint16_t kVK_Space = 0x31;
inline constexpr std::uint16_t kVK_Delete = 0x33;
inline constexpr std::uint16_t kVK_Escape = 0x35;
inline constexpr std::uint16_t kVK_ANSI_KeypadEnter = 0x4C;
inline constexpr std::uint16_t kVK_Home = 0x73;
inline constexpr std::uint16_t kVK_End = 0x77;
inline constexpr std::uint16_t kVK_F1 = 0x7A;
inline constexpr std::uint16_t kVK_F2 = 0x78;
inline constexpr std::uint16_t kVK_F3 = 0x63;
inline constexpr std::uint16_t kVK_F4 = 0x76;
inline constexpr std::uint16_t kVK_F5 = 0x60;
inline constexpr std::uint16_t kVK_F6 = 0x61;
inline constexpr std::uint16_t kVK_F7 = 0x62;
inline constexpr std::uint16_t kVK_F8 = 0x64;
inline constexpr std::uint16_t kVK_F9 = 0x65;
inline constexpr std::uint16_t kVK_F10 = 0x6D;
inline constexpr std::uint16_t kVK_F11 = 0x67;
inline constexpr std::uint16_t kVK_F12 = 0x6F;
inline constexpr std::uint16_t kVK_F13 = 0x69;
inline constexpr std::uint16_t kVK_F14 = 0x6B;
inline constexpr std::uint16_t kVK_F15 = 0x71;
inline constexpr std::uint16_t kVK_F16 = 0x6A;
inline constexpr std::uint16_t kVK_F17 = 0x40;
inline constexpr std::uint16_t kVK_F18 = 0x4F;
inline constexpr std::uint16_t kVK_F19 = 0x50;

} // namespace nc::base::keycodes
