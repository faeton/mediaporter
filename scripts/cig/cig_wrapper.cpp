#include "cig.h"

extern "C" {

__attribute__((visibility("default")))
int cig_calc(unsigned char* grappa, unsigned char* data, int data_len, unsigned char* cig_out, int* cig_len) {
    return cigCalc(grappa, data, data_len, cig_out, cig_len);
}

}
