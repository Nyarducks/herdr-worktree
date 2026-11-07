// The shapes of names and values, shared by the manifest and the CLI.

/** Instance name: ssh Host alias, herdr target, compose project. */
export const NAME_RE = /^[a-z][a-z0-9-]{0,31}$/;
/** Image name: a directory under docker/. */
export const IMAGE_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
export const HOST_RE = /^[A-Za-z0-9._:-]+$/;
export const USER_RE = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
/** A remote checkout path; `~` is expanded on the host, so it stays unquoted. */
export const DIR_RE = /^[A-Za-z0-9._/~-]+$/;

export function nameProblem(name: string): string | undefined {
  return NAME_RE.test(name)
    ? undefined
    : `invalid instance name '${name}' (lowercase letter first, then a-z 0-9 -, at most 32)`;
}

/** A label is used after `--machine` and as the <label>/<pane> prefix. */
export function labelProblem(label: string): string | undefined {
  // eslint-disable-next-line no-control-regex
  return label.length >= 1 && label.length <= 64 && !/[\s/|\u0000-\u001f\u007f-\u009f]/u.test(label)
    ? undefined
    : `invalid label '${label}' (1-64 characters, no spaces, '/' or '|')`;
}

export function imageProblem(image: string): string | undefined {
  return IMAGE_RE.test(image)
    ? undefined
    : `invalid image name '${image}' (a-z 0-9 . _ -, starting with a letter or digit)`;
}

export function portProblem(port: number): string | undefined {
  return Number.isInteger(port) && port >= 1 && port <= 65535 ? undefined : `invalid port '${port}'`;
}

export function hostProblem(host: string): string | undefined {
  return HOST_RE.test(host) ? undefined : `invalid host '${host}' (an IP address or host name)`;
}

export function userProblem(user: string): string | undefined {
  return USER_RE.test(user) ? undefined : `invalid user '${user}'`;
}

/** An identity file path goes into an ssh config included at the top of
 *  ~/.ssh/config, where whitespace, quotes or a newline would break (or
 *  inject into) every ssh call on the machine. */
export function identityProblem(identity: string): string | undefined {
  // eslint-disable-next-line no-control-regex
  return identity.length >= 1 && !/[\s"'\\\u0000-\u001f\u007f]/u.test(identity)
    ? undefined
    : `invalid identity '${identity}' (a path without spaces, quotes, backslashes or control characters)`;
}

export function dirProblem(dir: string): string | undefined {
  return DIR_RE.test(dir) ? undefined : `invalid dir '${dir}' (letters, digits, . _ - / ~)`;
}
