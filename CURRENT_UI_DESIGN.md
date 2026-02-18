# ZapShare UI Style Guide: Current Implementation

This document describes the current user interface design for the ZapShare iOS Home Screen, following the reversion to the "Clean Gradient & Bento Grid" design.

## 1. Core Visual Language

### Color Palette
The app uses a sophisticated dark theme with high-contrast accents derived from the brand identity.

*   **Primary Brand Color**: `Zap Yellow`
    *   `kZapPrimary` (Light): `#FFD84D`
    *   `kZapPrimaryDark` (Dark): `#F5C400`
*   **Background Colors**: `Soft Charcoal Gradient`
    *   Top: `#0E1116`
    *   Bottom: `#07090D`
*   **Surface Colors**:
    *   `kZapSurface`: `#1C1C1E` (Standard iOS Dark Gray)
    *   Secondary Cards: Dark glassy gradient (Dark Gray with opacity)
*   **Text Colors**:
    *   Headings: `Colors.white`
    *   Subtitles: `Colors.grey` / `#9CA3AF`
    *   Accents on Yellow: `Colors.black`

### Background Style
*   **Type**: Vertical Linear Gradient.
*   **Description**: A seamless fade from a soft charcoal top (`#0E1116`) to a deep near-black bottom (`#07090D`).
*   **Atmosphere**: Creates a premium, depth-filled void that allows the colorful interactive elements to pop.

## 2. Layout Structure (Bento Grid)

The main dashboard utilizes a **Bento Grid** layout pattern to organize primary actions efficiently.

### A. Primary Action Card ("Send")
*   **Size**: Large, vertical pill shape (Height: 304px).
*   **Position**: Left side, occupying 50% width.
*   **Design**: 
    *   **Background**: diagonal gradient from `kZapPrimary` to `kZapPrimaryDark`.
    *   **Style**: High visibility, simulating a physical "button" or card.
    *   **Decoration**: Contains a large, semi-transparent decorative icon (`Icons.arrow_upward_rounded`) in the bottom right for depth.
    *   **Content**: 
        *   Top: Icon pill (Yellow circular pill with black icon).
        *   Bottom: "Send" title (Black, Bold) and "Share Files" subtitle (Dark Gray).
*   **Interaction**: `HapticFeedback.mediumImpact` on tap.

### B. Secondary Action Cards ("Receive" & "History")
*   **Size**: Smaller, stacked horizontal cards (Height: 144px each).
*   **Position**: Right column.
*   **Design**:
    *   **Background**: Semi-transparent dark surface (`#1C1C1E` with opacity), creating a "glassy" dark look over the background gradient.
    *   **Border**: Subtle white border (`Colors.white.withOpacity(0.08)`).
    *   **Content**:
        *   "Receive": Arrow down icon, white text.
        *   "History": History clock icon, white text.

### C. Status Card
*   **Location**: Below the main grid.
*   **Design**: Full-width container.
*   **Style**: Minimalist dark container with very low opacity white background (`0.04`) and border (`0.06`).
*   **Content**: 
    *   Icon: "Wifi Tethering" in a yellow-tinted container.
    *   Text: "Ready to Share" (White) with explanatory subtitle (Grey).

## 3. Typography & Icons
*   **Font**: System Default (San Francisco on iOS).
*   **Weights**:
    *   Headings: `FontWeight.w700` (Bold)
    *   Labels: `FontWeight.w500` (Medium)
    *   Section Headers ("DASHBOARD"): `FontWeight.bold` with `letterSpacing: 1.5` (All Caps).
*   **Icons**: Rounded Material Icons (`Icons.rounded`) for a friendly, modern feel.

## 4. Animations & Interactions
*   **Entrance**: Exploring `FadeTransition` on screen load.
*   **Touch**: All interactive cards feature `InkWell` ripples or scale effects (implicit in GestureDetector config) and Haptic Feedback.
*   **Transitions**: Smooth page routing to sub-screens.

## Summary
The current UI prioritizes **clarity and accessibility** using a grid-based approach. It avoids excessive visual noise (like the liquid blobs) in favor of a clean, professional dark mode aesthetic that highlights the primary action (Sending files) with the brand's signature yellow color.
