// The iOS app's entry point: everything else is in libskate3_ios.a, where
// rex_ios_main hands the process to SDL/UIKit (windowed_app_main_sdl.cpp).
int rex_ios_main(int argc, char* argv[]);

int main(int argc, char* argv[]) {
  return rex_ios_main(argc, argv);
}
