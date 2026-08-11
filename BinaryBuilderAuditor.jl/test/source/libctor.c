// A translation unit with a static constructor; when this object is pulled into a
// shared library the constructor runs at load time, but a static link will drop the
// whole member unless something forcibly retains it.
static int ctor_ran = 0;

__attribute__((constructor)) static void set_ctor_ran(void) {
    ctor_ran = 1;
}

int ctor_status(void) {
    return ctor_ran;
}
