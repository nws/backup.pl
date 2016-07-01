#!/usr/bin/env perl
use Test::More;

ok(!system(qw{./src/bulwark.pl --config t/lucy.cfg.pl}), "can parse lucy.cfg.pl");

done_testing();
