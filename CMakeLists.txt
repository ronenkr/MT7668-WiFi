cmake_minimum_required(VERSION 3.16)
project(mt7668-wifi LANGUAGES NONE)

# ---------------------------------------------------------------------------
# This is an out-of-tree Linux *kernel module*. It cannot be compiled through
# CMake's normal compiler pipeline -- kernel modules must be built by the
# kernel's own kbuild system (it supplies the right include paths, module
# versioning/symvers, and object format). CMake here is a configure/build/
# install *wrapper* that invokes kbuild directly:
#
#   configure -> detect kernel headers + matching compiler, validate them
#   build     -> invoke kbuild (produces the .ko next to the driver sources,
#                same as it always has -- kbuild does not support building
#                into a separate CMake binary dir for out-of-tree modules)
#   install   -> copy the .ko + firmware into place, refresh module deps,
#                enable autoload (requires root: sudo cmake --install build)
#
# This driver's kbuild Makefile (drv_wlan/MT6632/wlan/Makefile) is hardcoded
# to the USB host interface and a fixed module name -- that's this project's
# actual, tested scope (a specific USB dongle), not a multi-transport build,
# so there's nothing left for a wrapper Makefile to parameterize; CMake calls
# kbuild's own `make -C $(KERNEL_DIR) M=$(DRIVER_SRC_DIR) modules` directly.
# ---------------------------------------------------------------------------

execute_process(COMMAND uname -r OUTPUT_VARIABLE UNAME_R OUTPUT_STRIP_TRAILING_WHITESPACE)
set(KERNEL_DIR "/lib/modules/${UNAME_R}/build" CACHE PATH "Kernel headers/build directory")

if(NOT EXISTS "${KERNEL_DIR}/Makefile")
    message(FATAL_ERROR
        "No kernel build directory at ${KERNEL_DIR}.\n"
        "Install headers for the running kernel, e.g.:\n"
        "  sudo apt install linux-headers-${UNAME_R}\n"
        "or pass -DKERNEL_DIR=/path/to/kernel/build")
endif()

# --- Find a compiler matching the one the kernel itself was built with. ---
# Mismatched compiler major versions can produce a module that loads but
# behaves oddly, or that GCC plugins/flags in the kernel Makefile reject
# outright (this driver hit exactly that: the kernel's Makefile passed a
# GCC-12-only flag that GCC 11 didn't understand).
set(KERNEL_CC "" CACHE STRING "Compiler to build the module with (auto-detected if empty)")

if(NOT KERNEL_CC)
    execute_process(COMMAND cat /proc/version OUTPUT_VARIABLE PROC_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE)
    string(REGEX MATCH "gcc-([0-9]+)" GCC_MATCH "${PROC_VERSION}")
    if(CMAKE_MATCH_1)
        find_program(DETECTED_CC NAMES "gcc-${CMAKE_MATCH_1}")
        if(DETECTED_CC)
            set(KERNEL_CC "${DETECTED_CC}")
            message(STATUS "Kernel was built with gcc-${CMAKE_MATCH_1}; using ${DETECTED_CC}")
        else()
            message(WARNING
                "Kernel was built with gcc-${CMAKE_MATCH_1} but it isn't installed.\n"
                "  sudo apt install gcc-${CMAKE_MATCH_1}\n"
                "Falling back to the default 'gcc' -- the build may fail on a flag mismatch.")
            set(KERNEL_CC "gcc")
        endif()
    else()
        message(WARNING "Could not parse compiler version out of /proc/version; falling back to 'gcc'.")
        set(KERNEL_CC "gcc")
    endif()
else()
    message(STATUS "Using user-specified compiler: ${KERNEL_CC}")
endif()

find_program(MAKE_PROGRAM NAMES make gmake REQUIRED)

set(DRIVER_SRC_DIR "${CMAKE_SOURCE_DIR}/drv_wlan/MT6632/wlan")
set(MODULE_NAME "wlan_mt76x8_usb")
set(MODULE_KO "${DRIVER_SRC_DIR}/${MODULE_NAME}.ko")
set(FIRMWARE_DIR "${CMAKE_SOURCE_DIR}/7668_firmware")

message(STATUS "MT7668 WiFi driver configuration:")
message(STATUS "  Running kernel : ${UNAME_R}")
message(STATUS "  Kernel headers : ${KERNEL_DIR}")
message(STATUS "  Compiler       : ${KERNEL_CC}")
message(STATUS "  Module output  : ${MODULE_KO}")

# --- build -----------------------------------------------------------------
add_custom_target(driver ALL
    COMMAND ${MAKE_PROGRAM} -C ${KERNEL_DIR} M=${DRIVER_SRC_DIR} CC=${KERNEL_CC} modules
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Building ${MODULE_NAME}.ko via kbuild"
    VERBATIM
)

add_custom_target(clean-driver
    COMMAND ${MAKE_PROGRAM} -C ${KERNEL_DIR} M=${DRIVER_SRC_DIR} clean
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Cleaning kbuild artifacts"
    VERBATIM
)

# Convenience targets: `cmake --build build --target load` / `--target unload`
add_custom_target(load
    COMMAND sudo insmod ${MODULE_KO}
    DEPENDS driver
    COMMENT "Loading ${MODULE_NAME}.ko (sudo)"
    VERBATIM
)
add_custom_target(unload
    COMMAND sudo rmmod ${MODULE_NAME}
    COMMENT "Unloading ${MODULE_NAME} (sudo)"
    VERBATIM
)

# --- install -----------------------------------------------------------------
install(FILES ${MODULE_KO}
    DESTINATION "/lib/modules/${UNAME_R}/extra"
)

file(GLOB FIRMWARE_FILES "${FIRMWARE_DIR}/*.bin" "${FIRMWARE_DIR}/*.dat" "${FIRMWARE_DIR}/wifi.cfg")
install(FILES ${FIRMWARE_FILES}
    DESTINATION "/lib/firmware"
)

install(CODE "
    message(STATUS \"Running depmod -a\")
    execute_process(COMMAND depmod -a)

    message(STATUS \"Enabling autoload via /etc/modules-load.d\")
    file(WRITE /etc/modules-load.d/mt7668-wifi.conf \"${MODULE_NAME}\n\")
")

message(STATUS "")
message(STATUS "Next steps:")
message(STATUS "  cmake --build <builddir>            # build the .ko")
message(STATUS "  sudo cmake --install <builddir>     # install module + firmware, enable autoload")
