#include "Application.h"

// Linux needs no platform preparation before the application runs: the process
// already has a usable stdout for `--scan`, and there is no console-window
// problem to work around the way there is on Windows.
int main(int argc, char *argv[])
{
    return segmenter::runApplication(argc, argv);
}
