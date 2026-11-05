#ifndef LINK_RPMSG_H
#define LINK_RPMSG_H

#include <stddef.h>
#include <stdint.h>

/* Goi lai moi khi nhan du mot dong lenh (khong gom '\n'), tu task link_rx. */
typedef void (*link_line_fn)(const char *line);

/* Khoi tao RPMsg-Lite (remote), cho link up, tao endpoint + announce kenh,
 * roi tao task link_rx goi on_line cho tung dong. Goi tu mot task (sau khi scheduler chay). */
void link_start(link_line_fn on_line);

/* Gui mot ban ghi (dong '#...' hoac block .chau). Chi goi tu app_task.
 * Bo qua neu Linux chua gui gi (chua biet dia chi endpoint ben kia). */
void link_send(const uint8_t *buf, size_t len);

#endif /* LINK_RPMSG_H */
