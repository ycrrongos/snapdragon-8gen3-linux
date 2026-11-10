# Build guide

The current reproducible source build is documented in [docs/BUILDING.md](docs/BUILDING.md).
Use `make prepare`, then `JOBS=8 make build`. The historical pmbootstrap6.12 recipe
is superseded by the pinned7.2-rc5 source/patch/config. Default build outputs are
Image/DTB/modules, not a flashable OS image. See the build guide for deployment inputs.
