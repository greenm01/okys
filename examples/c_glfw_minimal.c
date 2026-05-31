/*
 * Source-only GL integration example.
 *
 * The application owns GLFW, the GL context, and buffer presentation. Okys owns
 * only its context and sokol_gfx setup after okySetupGL sees the current GL
 * context.
 */

#include "okys.h"

#include <GLFW/glfw3.h>
#include <stdio.h>

int main(void) {
    const int sample_count = 4;

    if (!glfwInit()) {
        fprintf(stderr, "failed to initialize GLFW\n");
        return 1;
    }

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    glfwWindowHint(GLFW_STENCIL_BITS, 8);
    glfwWindowHint(GLFW_DEPTH_BITS, 16);
    glfwWindowHint(GLFW_SAMPLES, sample_count);

    GLFWwindow *window = glfwCreateWindow(800, 480, "okys GLFW GL", NULL, NULL);
    if (window == NULL) {
        fprintf(stderr, "failed to create GLFW window\n");
        glfwTerminate();
        return 1;
    }
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    OKYcontext *vg = okyCreate(OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    if (vg == NULL) {
        fprintf(stderr, "failed to create okys context\n");
        glfwDestroyWindow(window);
        glfwTerminate();
        return 1;
    }
    if (!okySetupGL(vg, sample_count)) {
        fprintf(stderr, "failed to setup okys GL backend\n");
        okyDelete(vg);
        glfwDestroyWindow(window);
        glfwTerminate();
        return 1;
    }

    while (!glfwWindowShouldClose(window)) {
        int width = 0;
        int height = 0;
        glfwGetFramebufferSize(window, &width, &height);

        okyBeginFrame(vg, (float)width, (float)height, 1.0f);

        okyBeginPath(vg);
        okyRect(vg, 0.0f, 0.0f, (float)width, (float)height);
        okyFillColor(vg, okyRGBA(28, 31, 36, 255));
        okyFill(vg);

        okyBeginPath(vg);
        okyRoundedRect(vg, 64.0f, 64.0f, 220.0f, 96.0f, 18.0f);
        okyFillColor(vg, okyRGBA(55, 145, 210, 255));
        okyFill(vg);

        okyBeginPath(vg);
        okyMoveTo(vg, 360.0f, 96.0f);
        okyBezierTo(vg, 430.0f, 20.0f, 540.0f, 180.0f, 640.0f, 88.0f);
        okyStrokeColor(vg, okyRGBA(238, 235, 222, 255));
        okyStrokeWidth(vg, 8.0f);
        okyLineCap(vg, OKY_ROUND);
        okyStroke(vg);

        okyEndFrame(vg);

        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    okyDelete(vg);
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}
