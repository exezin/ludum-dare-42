package collision;

import math.Vec3;
import math.Plane;
import math.Utils;
import math.Triangle;

typedef Packet = {
	// r3 (world) space
	r3_position:     Vec3,
	r3_velocity:     Vec3,

	// ellipsoid space
	e_radius:        Vec3,
	e_inv_radius:    Vec3,
	e_position:      Vec3,
	e_velocity:      Vec3,
	e_norm_velocity: Vec3,
	e_base_point:    Vec3,

	// internal hit information
	found_collision:  Bool,
	nearest_distance: Float,
	intersect_point:  Vec3,
	intersect_time:   Float,

	// user hit information
	contacts:         Array<Plane>
}

typedef TriQueryCb = Vec3->Vec3->Array<Triangle>;

// This implements the improvements to Kasper Fauerby's "Improved Collision
// detection and Response" proposed by Jeff Linahan's "Improving the Numerical
// Robustness of Sphere Swept Collision Detection"
typedef Response = ResponseArgh;
// typedef Response = ResponseFaster;

class ResponseFaster {
	static var VERY_CLOSE_DIST: Float = 0.005;

	static function collide_with_world(packet: Packet, e_position: Vec3, e_velocity: Vec3, tri_query: TriQueryCb) {
		var first_plane: Plane = new Plane(new Vec3(0, 0, 0), new Vec3(0, 0, 0));
		var dest: Vec3 = e_position + e_velocity;

		// check for collision
		for (i in 0...3) {
			packet.e_norm_velocity = e_velocity.copy();
			packet.e_norm_velocity.normalize();
			packet.e_velocity = e_velocity.copy();
			packet.e_base_point = e_position.copy();
			packet.found_collision = false;
			packet.nearest_distance = 1e20;

			// check for collision
			// NB: scale the octree query by velocity to make sure we still get the
			// triangles we need at high velocities. without this, long falls will
			// jam you into the floor. A bit (25%) of padding is added so I can
			// sleep at night.
			//
			// TODO: can this be cached? max velocity will never increase, so
			// it seems like it'd be safe to query the max size only once, before
			// hitting this function at all.
			var scale = Utils.max(1.5, e_velocity.length()) * 1.25;

			var r3_position = e_position * packet.e_radius;
			var query_radius = packet.e_radius * scale;
			var min = r3_position - query_radius;
			var max = r3_position + query_radius;
			var tris = tri_query(min, max);
			check_collision(packet, tris);

			// no collision
			if (!packet.found_collision) {
				return dest;
			}

			var touch_point = e_position + e_velocity * packet.intersect_time;

			var pn = touch_point - packet.intersect_point;
			pn.normalize();

			var p = new Plane(packet.intersect_point, pn);
			var n = p.normal / packet.e_radius;
			n.normalize();

			var dist = e_velocity.length() * packet.intersect_time;
			var short_dist = Utils.max(dist - VERY_CLOSE_DIST, 0.0);

			var nvel = e_velocity.copy();
			nvel.normalize();
			e_position += nvel * short_dist;

			packet.contacts.push(new Plane(p.origin * packet.e_radius, n));

			if (i == 0) {
				var long_radius = 1.0 + VERY_CLOSE_DIST;
				first_plane = p;

				dest -= first_plane.normal * (first_plane.signed_distance(dest) - long_radius);
				e_velocity = dest - e_position;
			} else if (i == 1) {
				var second_plane = p;
				var crease = Vec3.cross(first_plane.normal, second_plane.normal);
				crease.normalize();

				var dis = Vec3.dot(dest - e_position, crease);
				e_velocity = crease * dis;
				dest = e_position + e_velocity;
			}
		}

		return e_position;
	}

	// explanation: getting vecs out of the triangle generates a lot of garbage
	// due to the way they are stored, so we need to do this the hard way.
	static function scale_tri(out0: Vec3, out1: Vec3, out2: Vec3, input: Triangle, scale: Vec3) {
		out0.x = input.v0_x * scale.x;
		out0.y = input.v0_y * scale.y;
		out0.z = input.v0_z * scale.z;

		out1.x = input.v1_x * scale.x;
		out1.y = input.v1_y * scale.y;
		out1.z = input.v1_z * scale.z;

		out2.x = input.v2_x * scale.x;
		out2.y = input.v2_y * scale.y;
		out2.z = input.v2_z * scale.z;
	}

	static var tmp_v0 = new Vec3(0, 0, 0);
	static var tmp_v1 = new Vec3(0, 0, 0);
	static var tmp_v2 = new Vec3(0, 0, 0);

	static function check_collision(packet: Packet, tris: Array<Triangle>) {
		for (tri in tris) {
			scale_tri(tmp_v0, tmp_v1, tmp_v2, tri, packet.e_inv_radius);
			if (!tmp_v0.eq(tri.v0 / packet.e_radius)) {
				trace("uh oh 0");
			}
			if (!tmp_v1.eq(tri.v1 / packet.e_radius)) {
				trace("uh oh 1");
			}
			if (!tmp_v2.eq(tri.v2 / packet.e_radius)) {
				trace("uh oh 2");
			}
			Collision.check_triangle(packet, tmp_v0, tmp_v1, tmp_v2);
		}
	}

	public static function update(position: Vec3, velocity: Vec3, radius: Vec3, gravity: Vec3, query: TriQueryCb) {
		var packet: Packet = {
			r3_position: position,
			r3_velocity: velocity,
			e_radius: radius,
			e_inv_radius: Vec3.rcp(radius),
			e_position: position / radius,
			e_velocity: velocity / radius,
			e_norm_velocity: Vec3.zero(),
			e_base_point: Vec3.zero(),
			found_collision: false,
			nearest_distance: 0.0,
			intersect_point: Vec3.zero(),
			intersect_time: 0.0,
			contacts: []
		};

		// convert to e-space
		var e_position = packet.e_position.copy();
		var e_velocity = packet.e_velocity.copy();

		// do velocity iteration
		var final_position = collide_with_world(packet, e_position, e_velocity, query);

		// convert velocity to e-space
		e_velocity += gravity / packet.e_radius;

		// do gravity iteration
		final_position = collide_with_world(packet, final_position, e_velocity, query);

		// convert back to r3-space
		packet.r3_position = final_position     * packet.e_radius;
		packet.r3_velocity = packet.r3_position - position;

		return {
			position: packet.r3_position,
			velocity: packet.r3_velocity,
			contacts: packet.contacts
		};
	}
}
