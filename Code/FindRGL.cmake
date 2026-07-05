# Copyright 2020-2021, Robotec.ai sp. z o.o.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set(RGL_VERSION 0.21.0)
set(RGL_TAG v${RGL_VERSION})

# Metadata files used to determine if RGL download is required
set(RGL_VERSION_METADATA_FILE ${CMAKE_CURRENT_BINARY_DIR}/RGL_VERSION)
set(ROS_DISTRO_METADATA_FILE ${CMAKE_CURRENT_BINARY_DIR}/ROS_DISTRO)

# Determine RGL binary to download based on ROS distro
set(ROS_DISTRO $ENV{ROS_DISTRO})
if($ENV{ROS_DISTRO} STREQUAL "humble")
    set(RGL_LINUX_ZIP_FILENAME_BASE RGL-full-linux-x64-humble)
elseif($ENV{ROS_DISTRO} STREQUAL "jazzy")
    set(RGL_LINUX_ZIP_FILENAME_BASE RGL-full-linux-x64-jazzy)
elseif($ENV{ROS_DISTRO} STREQUAL "kilted") # there is no release for kilted but jazzy one works properly
    set(RGL_LINUX_ZIP_FILENAME_BASE RGL-full-linux-x64-jazzy)
elseif($ENV{ROS_DISTRO} STREQUAL "lyrical")
    # No upstream RGL release for lyrical, and unlike kilted its rclcpp ABI diverged from jazzy's
    # (a few functions started taking shared_ptr args by const-ref instead of by value), so the
    # jazzy binary cannot be reused here. RGL must be built locally from source against lyrical.
    set(RGL_USE_LOCAL_BUILD TRUE)
    set(RGL_LOCAL_BUILD_DIR "${CMAKE_CURRENT_LIST_DIR}/3rdParty/rgl-lyrical-local-build" CACHE PATH
            "Path to a locally built RobotecGPULidar (lib/libRobotecGPULidar.so and include/rgl/api/...) \
used for ROS distros with no official RGL release.")
else()
    message(FATAL_ERROR "ROS not found or ROS distro not supported. Please use one of {humble, jazzy, kilted, lyrical}.")
endif ()
set(RGL_LINUX_ZIP_FILENAME ${RGL_LINUX_ZIP_FILENAME_BASE}.zip)

set(RGL_LINUX_ZIP_URL https://github.com/RobotecAI/RobotecGPULidar/releases/download/${RGL_TAG}/${RGL_LINUX_ZIP_FILENAME})
set(RGL_SRC_ROOT_URL https://raw.githubusercontent.com/RobotecAI/RobotecGPULidar/${RGL_TAG})

set(DEST_SO_DIR ${CMAKE_CURRENT_BINARY_DIR}/3rdParty/RobotecGPULidar)
set(DEST_API_DIR ${DEST_SO_DIR}/include/rgl/api)

set(SO_FILENAME libRobotecGPULidar.so)

set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)

# This check is performed to mitigate Clion multi-profile project reload issues
# (each profile would execute the file download, extraction and removal without it).
# Note: This check does not provide a full assurance (not atomic) but is good enough
#       since this is a Clion-specific issue.
set(RGL_DOWNLOAD_IN_PROGRESS_FILE ${CMAKE_CURRENT_BINARY_DIR}/RGL_DOWNLOAD_IN_PROGRESS)
if (NOT EXISTS ${RGL_DOWNLOAD_IN_PROGRESS_FILE})
    FILE(TOUCH ${RGL_DOWNLOAD_IN_PROGRESS_FILE})

    # Read metadata
    set(RGL_VERSION_METADATA " ")
    set(ROS_DISTRO_METADATA " ")
    if (EXISTS ${RGL_VERSION_METADATA_FILE})
        file(READ ${RGL_VERSION_METADATA_FILE} RGL_VERSION_METADATA)
    endif ()
    if (EXISTS ${ROS_DISTRO_METADATA_FILE})
        file(READ ${ROS_DISTRO_METADATA_FILE} ROS_DISTRO_METADATA)
    endif ()

    # If metadata does not match, (re)fetch RGL
    if ((NOT ${RGL_VERSION_METADATA} STREQUAL ${RGL_VERSION}) OR (NOT ${ROS_DISTRO_METADATA} STREQUAL ${ROS_DISTRO}))
        if (RGL_USE_LOCAL_BUILD)
            if (NOT EXISTS ${RGL_LOCAL_BUILD_DIR}/lib/${SO_FILENAME})
                message(FATAL_ERROR "RGL_USE_LOCAL_BUILD is set for ROS_DISTRO=${ROS_DISTRO}, but "
                        "${RGL_LOCAL_BUILD_DIR}/lib/${SO_FILENAME} was not found. Build RobotecGPULidar from "
                        "source against your sourced ROS2 environment (./setup.py --with-ros2, with "
                        "OptiX_INSTALL_DIR set) and place lib/${SO_FILENAME} plus include/rgl/api/... under "
                        "${RGL_LOCAL_BUILD_DIR}, or point RGL_LOCAL_BUILD_DIR at an existing build.")
            endif ()
            message("Using locally built RGL from " ${RGL_LOCAL_BUILD_DIR} " for ROS " ${ROS_DISTRO} "...")

            file(COPY ${RGL_LOCAL_BUILD_DIR}/lib/${SO_FILENAME} DESTINATION ${DEST_SO_DIR})
            file(COPY ${RGL_LOCAL_BUILD_DIR}/include/rgl DESTINATION ${DEST_SO_DIR}/include)
        else ()
            message("Downloading RGL " ${RGL_VERSION} " for ROS " ${ROS_DISTRO} "...")

            # Download the RGL archive files
            file(DOWNLOAD
                    ${RGL_LINUX_ZIP_URL}
                    ${DEST_SO_DIR}/${RGL_LINUX_ZIP_FILENAME}
            )

            # Extract the contents of the downloaded archive files
            file(ARCHIVE_EXTRACT INPUT ${DEST_SO_DIR}/${RGL_LINUX_ZIP_FILENAME}
                    DESTINATION ${DEST_SO_DIR}
                    PATTERNS ${SO_FILENAME}
                    VERBOSE
            )

            # Remove the unwanted byproducts
            file(REMOVE ${DEST_SO_DIR}/${RGL_LINUX_ZIP_FILENAME})

            # Download API headers
            file(DOWNLOAD
                    ${RGL_SRC_ROOT_URL}/include/rgl/api/core.h
                    ${DEST_API_DIR}/core.h
            )
            file(DOWNLOAD
                    ${RGL_SRC_ROOT_URL}/extensions/ros2/include/rgl/api/extensions/ros2.h
                    ${DEST_API_DIR}/extensions/ros2.h
            )
        endif ()

        # Save current metadata
        file(WRITE ${RGL_VERSION_METADATA_FILE} ${RGL_VERSION})
        file(WRITE ${ROS_DISTRO_METADATA_FILE} ${ROS_DISTRO})
    endif ()

    # Remove the unwanted byproducts
    file(REMOVE ${RGL_DOWNLOAD_IN_PROGRESS_FILE})
else ()
    message(WARNING "Omitting the RobotecGPULidar library download. This is intended when using the Clion multi-profile"
            " project reload. This may also happen due to interruption of previous project configurations. If you have"
            " any issues related to the libRobotecGPULidar.so file please clear cmake cache before next build attempt."
    )
endif ()

# Paths used by external targets
set(RGL_SO_DIR ${DEST_SO_DIR}/${SO_FILENAME})
set(RGL_INCLUDE_DIR ${DEST_SO_DIR}/include)
