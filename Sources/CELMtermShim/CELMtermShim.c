#include "CELMtermShim.h"

#include <sys/ioctl.h>

int elmterm_get_winsize(int fd, uint16_t *rows, uint16_t *cols) {
    struct winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0) {
        return -1;
    }
    if (rows) *rows = ws.ws_row;
    if (cols) *cols = ws.ws_col;
    return 0;
}
