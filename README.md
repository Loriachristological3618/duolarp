# duolarp
iphone duo animations for macbook

download: [nipuntal.vercel.app/duolarp](https://nipuntal.vercel.app/duolarp)

## how it works
- reads the macbook's lid angle sensor (~10 readings a second) and predicts the hinge angle between readings
- while the lid moves, the screen is captured and redrawn through an exact perspective transform, so the picture stays fixed in space from a normal viewing position
- blur, shadow and colour fringing come from how far each pixel of the glass is from that frozen picture
- when the lid stops, the picture eases back onto the screen and everything switches off again

## what's in here
- `app/` duolarp itself: menu bar app, sensor, projection maths and the metal renderer
- `installer/` Install duolarp
- `uninstaller/` Uninstall duolarp
- `shared/` what uninstalling removes

## privacy
screen capture only runs while the lid is moving, frames never leave the gpu, nothing is saved, and it never uses the internet.

needs a macbook with a lid angle sensor (macbook air m2 or later, 14/16" macbook pro 2021 or later, 16" macbook pro 2019) on macos 14 or later.
