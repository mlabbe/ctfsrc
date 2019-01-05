# Frogtoss Capture the Flag #

![flag title](https://raw.githubusercontent.com/mlabbe/ctfsrc/master/images/titleimage.PNG)

This is the source code to the Pico-8 Cartridge "Frogtoss Capture the Flag".  Pico-8 is a fantasy console that places extreme limitations on what can be done.  A fully shipped and playable version is available:

- [In your browser](https://www.lexaloffle.com/bbs/?tid=32798)
- [As a downloadable executable with gamepad support](https://frogtoss.itch.io/capture-the-flag])

I am sharing the source code to Capture the Flag here under a public domain license so people can learn from it.

It contains an AABB and particle force-based physics engine with a second order euler integrator that runs at 60 fps on the restricted hardware.  This is used to simulate every physical entity in the game; only tuning values were necessary.  This may be a novel approach amongst Pico-8 cartridges.

## Table of Contents ##

- ctf.p8: the cart in original release format
- ctfsrc.lua: the source code in ctf.p8 in easy browsing format

