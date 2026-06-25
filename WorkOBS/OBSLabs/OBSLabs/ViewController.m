//
//  ViewController.m
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#import "ViewController.h"

#include <libavformat/avformat.h>
#include "wl_decoder.h"

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // Do any additional setup after loading the view.
    
    NSLog(@"%u", avformat_version());
}


- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];

    // Update the view, if already loaded.
}


@end
