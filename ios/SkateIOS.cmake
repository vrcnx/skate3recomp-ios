# iOS/iPadOS packaging for the skate3 target (included from the top-level
# CMakeLists.txt when IOS is set).
#
# CMake builds everything as static archives with Homebrew LLVM, then merges
# them into one archive, libskate3_ios.a. The app bundle, signing and install
# are Xcode's job: ios/project.yml (XcodeGen) links that archive into a thin
# app target, which keeps automatic provisioning and on-device debugging.

set(SKATE3_MOLTENVK_IOS_XCFRAMEWORK "" CACHE PATH
    "MoltenVK.xcframework (static) with ios-arm64 and simulator slices")
if(NOT EXISTS "${SKATE3_MOLTENVK_IOS_XCFRAMEWORK}")
    message(FATAL_ERROR
        "SKATE3_MOLTENVK_IOS_XCFRAMEWORK not found: '${SKATE3_MOLTENVK_IOS_XCFRAMEWORK}'. "
        "Extract MoltenVK-all.tar from https://github.com/KhronosGroup/MoltenVK/releases "
        "and point this at MoltenVK/MoltenVK/static/MoltenVK.xcframework.")
endif()
if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
    set(_skate3_mvk_slice ios-arm64_x86_64-simulator)
    set(SKATE3_IOS_SDK_NAME iphonesimulator)
else()
    set(_skate3_mvk_slice ios-arm64)
    set(SKATE3_IOS_SDK_NAME iphoneos)
endif()
add_library(skate3_moltenvk STATIC IMPORTED GLOBAL)
set_target_properties(skate3_moltenvk PROPERTIES
    IMPORTED_LOCATION "${SKATE3_MOLTENVK_IOS_XCFRAMEWORK}/${_skate3_mvk_slice}/libMoltenVK.a")
target_link_libraries(skate3 PRIVATE skate3_moltenvk)

# Walks a target's link interface and returns every static archive it pulls in
# (OBJECT libraries are already folded into their consumers). Anything that is
# not a target - frameworks, system libraries - lands in <extras_var>.
function(skate3_collect_static_archives target archives_var extras_var)
    set(_pending ${target})
    set(_seen)
    set(_archives)
    set(_extras)
    while(_pending)
        list(POP_FRONT _pending _item)
        if(_item MATCHES "^\\$<LINK_ONLY:(.+)>$")
            set(_item "${CMAKE_MATCH_1}")
        endif()
        if(_item MATCHES "^\\$<" OR _item IN_LIST _seen)
            continue()
        endif()
        list(APPEND _seen ${_item})
        if(NOT TARGET ${_item})
            list(APPEND _extras ${_item})
            continue()
        endif()
        get_target_property(_aliased ${_item} ALIASED_TARGET)
        if(_aliased)
            list(APPEND _pending ${_aliased})
            continue()
        endif()
        # volk defines a global *variable* named vkGetInstanceProcAddr. Nothing
        # calls into volk (the runtime takes MoltenVK's exports directly on
        # iOS), and letting the linker see both could bind the call to data.
        if(_item STREQUAL "volk")
            continue()
        endif()
        get_target_property(_type ${_item} TYPE)
        get_target_property(_imported ${_item} IMPORTED)
        if(_type STREQUAL "STATIC_LIBRARY")
            if(_imported)
                get_target_property(_location ${_item} IMPORTED_LOCATION)
                list(APPEND _archives "${_location}")
            else()
                list(APPEND _archives "$<TARGET_FILE:${_item}>")
            endif()
        endif()
        foreach(_property LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
            if(_property STREQUAL "LINK_LIBRARIES" AND (_imported OR _type STREQUAL "INTERFACE_LIBRARY"))
                continue()
            endif()
            get_target_property(_deps ${_item} ${_property})
            if(_deps)
                list(APPEND _pending ${_deps})
            endif()
        endforeach()
    endwhile()
    list(REMOVE_DUPLICATES _archives)
    list(REMOVE_DUPLICATES _extras)
    set(${archives_var} ${_archives} PARENT_SCOPE)
    set(${extras_var} ${_extras} PARENT_SCOPE)
endfunction()

set(SKATE3_IOS_OUTPUT_DIR "${CMAKE_BINARY_DIR}/ios")
set(SKATE3_IOS_ARCHIVE "${SKATE3_IOS_OUTPUT_DIR}/libskate3_ios.a")

# Collected at the end of configure, once every subdirectory has added its
# link dependencies.
cmake_language(DEFER DIRECTORY ${CMAKE_SOURCE_DIR} CALL skate3_ios_define_archive)
function(skate3_ios_define_archive)
    skate3_collect_static_archives(skate3 _archives _extras)
    file(GENERATE OUTPUT "${SKATE3_IOS_OUTPUT_DIR}/archives.txt"
        CONTENT "$<JOIN:${_archives},\n>\n")
    file(WRITE "${SKATE3_IOS_OUTPUT_DIR}/link-extras.txt" "${_extras}\n")
    add_custom_command(
        OUTPUT "${SKATE3_IOS_ARCHIVE}"
        COMMAND ${CMAKE_COMMAND} -E rm -f "${SKATE3_IOS_ARCHIVE}"
        COMMAND xcrun -sdk ${SKATE3_IOS_SDK_NAME} libtool -static -no_warning_for_no_symbols
            -o "${SKATE3_IOS_ARCHIVE}" ${_archives}
        DEPENDS ${_archives}
        COMMENT "Merging static archives into libskate3_ios.a"
        COMMAND_EXPAND_LISTS
        VERBATIM)
    add_custom_target(skate3_ios ALL DEPENDS "${SKATE3_IOS_ARCHIVE}")
    add_dependencies(skate3_ios skate3)
endfunction()
