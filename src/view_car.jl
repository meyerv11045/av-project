function get_vis(host::IPAddr = ip"127.0.0.1", default_port=8700)
    vis = Visualizer(MeshCat.CoreVisualizer(host, default_port), ["meshcat"])
    open(vis)
    delete!(vis)
    return vis
end

function configure_car!(mvis, state, joints, config)
    wb = joints[1]
    lsl = joints[6]
    rsl = joints[7]
    
    axis_roll = [1, 0, 0]
    axis_pitch = [0, 1, 0]
    axis_yaw = [0, 0, 1]
    
    q1 = [cos(config.roll_angle/2); sin(config.roll_angle/2)*axis_roll]
    q2 = [cos(config.pitch_angle/2); sin(config.pitch_angle/2)*axis_pitch]
    q3 = [cos(config.yaw_angle/2); sin(config.yaw_angle/2)*axis_yaw]
    s1 = q1[1]
    s2 = q2[1]
    s3 = q3[1]
    v1 = q1[2:4]
    v2 = q2[2:4]
    v3 = q3[2:4]
    s = s1*s2 - v1'*v2
    v = s1*v2+s2*v1+v1×v2
    q = [s; v]
    s12 = q[1]
    v12 = q[2:4]
    s = s12*s3 - v12'*v3
    v = s12*v3+s3*v12+v12×v3
    q = [s; v]

    set_configuration!(state, wb, [q; config.position])
    set_configuration!(state, lsl, config.steering_angle)
    set_configuration!(state, rsl, config.steering_angle)
    set_configuration!(mvis, configuration(state))
end

function configure_contact_points!(chevy)
    origin = RigidBodyDynamics.Point3D(bodies(chevy)[1].frame_definitions[1].from, [0.0,0,0])
    one_up = RigidBodyDynamics.Point3D(bodies(chevy)[1].frame_definitions[1].from, [0.0,0,1.0])
    dir_up = RigidBodyDynamics.FreeVector3D(one_up)

    hs = RigidBodyDynamics.HalfSpace3D(origin, dir_up)
    RigidBodyDynamics.add_environment_primitive!(chevy, hs)

    # define contact point on wheel origins (will need to change
    # this for sloped surfaces   
    friction_model = RigidBodyDynamics.ViscoelasticCoulombModel{Float64}(1000.0,1000.0,1000.0)
    normal_contact_model = RigidBodyDynamics.hunt_crossley_hertz() # investigate parameters if penetrating
    soft_contact_model = RigidBodyDynamics.SoftContactModel(normal_contact_model, friction_model)

    for (link_id, frame_id) in zip((6,6,7,8), (2,3,2,2))
        link = bodies(chevy)[link_id]
        frame = link.frame_definitions[frame_id].from
        pt = RigidBodyDynamics.Point3D(frame, SVector(0.0,-1.25,0))
        fl_dir = RigidBodyDynamics.Point3D(frame, SVector(1.0, 0, 0)) |> RigidBodyDynamics.FreeVector3D
        contact_point = RigidBodyDynamics.ContactPoint(pt, fl_dir, soft_contact_model)
        RigidBodyDynamics.add_contact_point!(link, contact_point)
    end
end

function view_car(vis; max_realtime_rate=1.0)
    delete!(vis)
    urdf_path = joinpath(dirname(pathof(VehicleSim)), "assets", "chevy.urdf")
    chevy = parse_urdf(urdf_path, floating=true)
    
    configure_contact_points!(chevy)

    state = MechanismState(chevy)

    wheel_angular_vel = 3.0
    drive_force = 1000.0
    steering_angle = 0.15

    for jid in 8:11
        wheel_joint = joints(chevy)[jid]
        set_velocity!(state, wheel_joint, -wheel_angular_vel)
    end
    @infiltrate
    
    chevy_visuals = URDFVisuals(urdf_path, package_path=[dirname(pathof(VehicleSim))])
    
    mvis = MechanismVisualizer(chevy, chevy_visuals, vis)

    all_joints = joints(chevy)
    config = CarConfig(SVector(0.0,0,4.0), 0.0, 0.0, 0.0, 0.0)
    configure_car!(mvis, state, all_joints, config)

    control! = (torques, t, state) -> begin
        torques .= 0.0
        steering_control!(torques, t, state; reference_angle=steering_angle)
        suspension_control!(torques, t, state)
    end

    @infiltrate


    wrenches! = (bodyid_to_wrench, t, state) -> begin
        RigidBodyDynamics.update_transforms!(state)
        df = t > 0.1 ? drive_force : 0.0
        for i = 7:8
            bodyid = BodyID(i)
            wheel = bodies(chevy)[i]
            frame = wheel.frame_definitions[1].from
            body_to_root = transform_to_root(state, bodyid, false)
            wrench = Wrench{Float64}(frame, [0.0,0,0], [df,0,0])
            bodyid_to_wrench[BodyID(i)] = transform(wrench, body_to_root)
        end
        nothing
    end
    
    vehicle_simulate(state, mvis, 10.0, control!, wrenches!; max_realtime_rate)
    #ts, qs, vs = RigidBodyDynamics.simulate(state, 5.0, control!)
    #MeshCatMechanisms.animate(mvis, ts, qs; realtimerate=1.0)
    #display(qs[end])
end

struct CarConfig
    position::SVector{3, Float64}
    roll_angle::Float64
    pitch_angle::Float64
    yaw_angle::Float64
    steering_angle::Float64
end



