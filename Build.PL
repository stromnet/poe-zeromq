use Module::Build;  
my $build = Module::Build->new
(
    module_name => 'POE::Wheel::ZeroMQ',
    license     => 'perl',
    requires    => {
        'ZeroMQ' => 0,
    }
);
$build->create_build_script;
