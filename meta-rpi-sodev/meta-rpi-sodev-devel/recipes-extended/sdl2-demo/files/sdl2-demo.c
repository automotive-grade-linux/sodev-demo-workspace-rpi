// SPDX-License-Identifier: Apache-2.0
#include <SDL2/SDL.h>
#include <SDL2/SDL_opengles2.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static const char *vs_src =
    "attribute vec2 a_pos;\n"
    "attribute vec3 a_col;\n"
    "varying vec3 v_col;\n"
    "uniform float u_time;\n"
    "uniform vec2 u_offset;\n"
    "void main() {\n"
    "  float c = cos(u_time);\n"
    "  float s = sin(u_time);\n"
    "  vec2 p = vec2(c*a_pos.x - s*a_pos.y, s*a_pos.x + c*a_pos.y);\n"
    "  v_col = a_col;\n"
    "  gl_Position = vec4(p + u_offset, 0.0, 1.0);\n"
    "}\n";

static const char *fs_src =
    "precision mediump float;\n"
    "varying vec3 v_col;\n"
    "void main() { gl_FragColor = vec4(v_col, 1.0); }\n";

static GLuint compile(GLenum t, const char *s) {
    GLuint sh = glCreateShader(t);
    glShaderSource(sh, 1, &s, NULL);
    glCompileShader(sh);
    GLint ok; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512]; glGetShaderInfoLog(sh, sizeof(log), NULL, log);
        fprintf(stderr, "shader compile: %s\n", log); exit(1);
    }
    return sh;
}

int main(int argc, char **argv) {
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1;
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    const int win_w = 640, win_h = 480;
    SDL_Window *win = SDL_CreateWindow("sdl2-demo (DomU VirtIO-GPU)",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
        win_w, win_h, SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN);
    if (!win) { fprintf(stderr, "win: %s\n", SDL_GetError()); return 1; }
    SDL_GLContext ctx = SDL_GL_CreateContext(win);
    if (!ctx) { fprintf(stderr, "ctx: %s\n", SDL_GetError()); return 1; }
    printf("GL_VERSION: %s\n", glGetString(GL_VERSION));
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));

    GLuint vs = compile(GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile(GL_FRAGMENT_SHADER, fs_src);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs); glAttachShader(prog, fs);
    glBindAttribLocation(prog, 0, "a_pos");
    glBindAttribLocation(prog, 1, "a_col");
    glLinkProgram(prog);
    glUseProgram(prog);
    GLint u_time   = glGetUniformLocation(prog, "u_time");
    GLint u_offset = glGetUniformLocation(prog, "u_offset");

    GLfloat verts[] = {
         0.0f,  0.4f, 1.0f, 0.0f, 0.0f,
        -0.4f, -0.3f, 0.0f, 1.0f, 0.0f,
         0.4f, -0.3f, 0.0f, 0.0f, 1.0f,
    };
    glEnableVertexAttribArray(0); glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 5*sizeof(GLfloat), verts);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 5*sizeof(GLfloat), verts+2);

    /* Touch / mouse state: triangle follows the contact point, background tint
     * cycles through hues while a finger is down. */
    float off_x = 0.0f, off_y = 0.0f;
    int   touching = 0;
    float clear_r = 0.10f, clear_g = 0.10f, clear_b = 0.15f;
    int   touch_count = 0;

    Uint32 t0 = SDL_GetTicks();
    int    running = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
            case SDL_QUIT:
                running = 0;
                break;
            case SDL_KEYDOWN:
                if (e.key.keysym.sym == SDLK_ESCAPE) running = 0;
                break;
            /* SDL2 normalizes touch coordinates to 0..1; convert to GL clip space. */
            case SDL_FINGERDOWN:
                touching = 1;
                off_x =  e.tfinger.x * 2.0f - 1.0f;
                off_y =  1.0f - e.tfinger.y * 2.0f;
                touch_count++;
                clear_r = 0.20f + 0.30f * sinf(touch_count * 0.7f);
                clear_g = 0.20f + 0.30f * sinf(touch_count * 1.1f + 2.0f);
                clear_b = 0.20f + 0.30f * sinf(touch_count * 1.3f + 4.0f);
                printf("FINGERDOWN id=%lld at (%.2f,%.2f) total=%d\n",
                       (long long)e.tfinger.fingerId, e.tfinger.x, e.tfinger.y, touch_count);
                fflush(stdout);
                break;
            case SDL_FINGERMOTION:
                if (touching) {
                    off_x = e.tfinger.x * 2.0f - 1.0f;
                    off_y = 1.0f - e.tfinger.y * 2.0f;
                }
                break;
            case SDL_FINGERUP:
                touching = 0;
                printf("FINGERUP   id=%lld\n", (long long)e.tfinger.fingerId);
                fflush(stdout);
                break;
            /* Mouse fallback for hosts without a touch panel (also useful for
             * QEMU's virtio-tablet which delivers SDL_MOUSE* events). */
            case SDL_MOUSEBUTTONDOWN:
                touching = 1;
                off_x = (float)e.button.x / win_w * 2.0f - 1.0f;
                off_y = 1.0f - (float)e.button.y / win_h * 2.0f;
                touch_count++;
                clear_r = 0.20f + 0.30f * sinf(touch_count * 0.7f);
                clear_g = 0.20f + 0.30f * sinf(touch_count * 1.1f + 2.0f);
                clear_b = 0.20f + 0.30f * sinf(touch_count * 1.3f + 4.0f);
                printf("MOUSEDOWN  at (%d,%d) total=%d\n",
                       e.button.x, e.button.y, touch_count);
                fflush(stdout);
                break;
            case SDL_MOUSEMOTION:
                if (touching) {
                    off_x = (float)e.motion.x / win_w * 2.0f - 1.0f;
                    off_y = 1.0f - (float)e.motion.y / win_h * 2.0f;
                }
                break;
            case SDL_MOUSEBUTTONUP:
                touching = 0;
                break;
            default:
                break;
            }
        }
        float t = (SDL_GetTicks() - t0) / 1000.0f;
        glUniform1f(u_time, t);
        glUniform2f(u_offset, off_x, off_y);
        glClearColor(clear_r, clear_g, clear_b, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        SDL_GL_SwapWindow(win);
    }
    SDL_GL_DeleteContext(ctx); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
