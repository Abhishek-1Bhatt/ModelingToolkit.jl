using ModelingToolkit, OrdinaryDiffEq, Test

@variables t
sts = @variables x1(t) x2(t) x3(t) x4(t)
params = @parameters u1(t) u2(t) u3(t) u4(t)
D = Differential(t)
eqs = [
    x1 + x2 + u1 ~ 0
    x1 + x2 + x3 + u2 ~ 0
    x1 + D(x3) + x4 + u3 ~ 0
    2*D(D(x1)) + D(D(x2)) + D(D(x3)) + D(x4) + u4 ~ 0
]
@named sys = ODESystem(eqs, t)

let dd = dummy_derivative(sys)
    has_dx1 = has_dx2 = false
    for eq in equations(dd)
        vars = ModelingToolkit.vars(eq)
        has_dx1 |= D(x1) in vars || D(D(x1)) in vars
        has_dx2 |= D(x2) in vars || D(D(x2)) in vars
    end
    @test has_dx1 ⊻ has_dx2 # only one of x1 and x2 can be a dummy derivative
    @test length(states(dd)) == length(equations(dd)) == 9
    @test length(states(structural_simplify(dd))) < 9
end

let pss = partial_state_selection(sys)
    @test length(equations(pss)) == 1
    @test length(states(pss)) == 2
    @test length(equations(ode_order_lowering(pss))) == 2
end

@parameters t σ ρ β
@variables x(t) y(t) z(t) a(t) u(t) F(t)
D = Differential(t)

eqs = [
       D(x) ~ σ*(y-x)
       D(y) ~ x*(ρ-z)-y + β
       0 ~ z - x + y
       0 ~ a + z
       u ~ z + a
    ]

lorenz1 = ODESystem(eqs,t,name=:lorenz1)
let al1 = alias_elimination(lorenz1)
    let lss = partial_state_selection(al1)
        @test length(equations(lss)) == 2
    end
end

# 1516
let
    @variables t
    D = Differential(t)

    @connector function Fluid_port(;name, p=101325.0, m=0.0, T=293.15)
        sts = @variables p(t)=p m(t)=m [connect=Flow] T(t)=T [connect=Stream]
        ODESystem(Equation[], t, sts, []; name=name)
    end

    #this one is for latter
    @connector function Heat_port(;name, Q=0.0, T=293.15)
        sts = @variables T(t)=T Q(t)=Q [connect=Flow]
        ODESystem(Equation[], t, sts, []; name=name)
    end

    # like ground but for fluid systems (fluid_port.m is expected to be zero in closed loop)
    function Compensator(;name, p=101325.0, T_back=273.15)
        @named fluid_port = Fluid_port()
        ps = @parameters p=p T_back=T_back
        eqs = [
               fluid_port.p ~ p
               fluid_port.T ~ T_back
              ]
        compose(ODESystem(eqs, t, [], ps; name=name), fluid_port)
    end

    function Source(;name, delta_p=100, T_feed=293.15)
        @named supply_port = Fluid_port() # expected to feed connected pipe -> m<0
        @named return_port = Fluid_port() # expected to receive from connected pipe -> m>0
        ps = @parameters delta_p=delta_p T_feed=T_feed
        eqs = [
               supply_port.m ~ -return_port.m
               supply_port.p ~ return_port.p + delta_p
               supply_port.T ~ instream(supply_port.T)
               return_port.T ~ T_feed
              ]
        compose(ODESystem(eqs, t, [], ps; name=name), [supply_port, return_port])
    end

    function Substation(;name, T_return=343.15)
        @named supply_port = Fluid_port() # expected to receive from connected pipe -> m>0
        @named return_port = Fluid_port() # expected to feed connected pipe -> m<0
        ps = @parameters T_return=T_return
        eqs = [
               supply_port.m ~ -return_port.m
               supply_port.p  ~ return_port.p # zero pressure loss for now
               supply_port.T ~ instream(supply_port.T)
               return_port.T ~ T_return
              ]
        compose(ODESystem(eqs, t, [], ps; name=name), [supply_port, return_port])
    end

    function Pipe(;name, L=1000, d=0.1, N=100, rho=1000, f=1)
        @named fluid_port_a = Fluid_port()
        @named fluid_port_b = Fluid_port()
        ps = @parameters L=L d=d rho=rho f=f N=N
        sts = @variables v(t)=0.0 dp_z(t)=0.0
        eqs = [
               fluid_port_a.m ~ -fluid_port_b.m
               fluid_port_a.T ~ instream(fluid_port_a.T)
               fluid_port_b.T ~ fluid_port_a.T
               v*pi*d^2/4*rho ~ fluid_port_a.m
               dp_z ~ abs(v)*v*0.5*rho*L/d*f  # pressure loss
               D(v)*rho*L ~ (fluid_port_a.p - fluid_port_b.p - dp_z) # acceleration of fluid m*a=sum(F)
              ]
        compose(ODESystem(eqs, t, sts, ps; name=name), [fluid_port_a, fluid_port_b])
    end
    function System(;name, L=10.0)
        @named compensator = Compensator()
        @named source = Source()
        @named substation = Substation()
        @named supply_pipe = Pipe(L=L)
        @named return_pipe = Pipe(L=L)
        subs = [compensator, source, substation, supply_pipe, return_pipe]
        ps = @parameters L=L
        eqs = [
               connect(compensator.fluid_port, source.supply_port)
               connect(source.supply_port, supply_pipe.fluid_port_a)
               connect(supply_pipe.fluid_port_b, substation.supply_port)
               connect(substation.return_port, return_pipe.fluid_port_b)
               connect(return_pipe.fluid_port_a, source.return_port)
              ]
        compose(ODESystem(eqs, t, [], ps; name=name), subs)
    end

    @named system = System(L=10)
    @unpack supply_pipe = system
    sys = structural_simplify(system)
    u0 = [system.supply_pipe.v => 0.1, system.return_pipe.v => 0.1, D(supply_pipe.v) => 0.0]
    # This is actually an implicit DAE system
    @test_throws Any ODEProblem(sys, u0, (0.0, 10.0), [])
    @test_throws Any ODAEProblem(sys, u0, (0.0, 10.0), [])
    prob = DAEProblem(sys, D.(states(sys)) .=> 0.0, u0, (0.0, 10.0), [])
    @test solve(prob, DFBDF()).retcode == :Success
end

# 1537
let
    @variables t
    @variables begin
        p_1(t)
        p_2(t)
        rho_1(t)
        rho_2(t)
        rho_3(t)
        u_1(t)
        u_2(t)
        u_3(t)
        mo_1(t)
        mo_2(t)
        mo_3(t)
        Ek_1(t)
        Ek_2(t)
        Ek_3(t)
    end

    @parameters dx = 100 f = 0.3 pipe_D = 0.4

    D = Differential(t)

    eqs = [
           p_1 ~ 1.2e5
           p_2 ~ 1e5
           u_1 ~ 10
           mo_1 ~ u_1 * rho_1
           mo_2 ~ u_2 * rho_2
           mo_3 ~ u_3 * rho_3
           Ek_1 ~ rho_1 * u_1 * u_1
           Ek_2 ~ rho_2 * u_2 * u_2
           Ek_3 ~ rho_3 * u_3 * u_3
           rho_1 ~ p_1 / 273.11 / 300
           rho_2 ~ (p_1 + p_2) * 0.5 / 273.11 / 300
           rho_3 ~ p_2 / 273.11 / 300
           D(rho_2) ~ (mo_1 - mo_3) / dx
           D(mo_2) ~ (Ek_1 - Ek_3 + p_1 - p_2) / dx - f / 2 / pipe_D * u_2 * u_2
          ]

    @named trans = ODESystem(eqs, t)

    sys = structural_simplify(trans)

    n = 3
    u = 0 * ones(n)
    rho = 1.2 * ones(n)

    u0 = [
          p_1 => 1.2e5
          p_2 => 1e5
          u_1 => 0
          u_2 => 0.1
          u_3 => 0.2
          rho_1 => 1.1
          rho_2 => 1.2
          rho_3 => 1.3
          mo_1 => 0
          mo_2 => 1
          mo_3 => 2
         ]
    prob = ODAEProblem(sys, u0, (0.0, 0.1))
    @test solve(prob, FBDF()).retcode == :Success
end
